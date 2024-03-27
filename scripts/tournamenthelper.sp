#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

const int GAME_STATE_NOTHING = 1;
const int GAME_STATE_VOTING = 2;
const int GAME_STATE_MATCH_STARTING = 3;
const int GAME_STATE_MATCH_IN_PROGRESS = 4;

const int VOTE_TYPE_NONE = 0;
const int VOTE_TYPE_READY = 1;
const int VOTE_TYPE_WINCOUNT = 2;

ConVar _conVar_insBotQuota = null;
ConVar _conVar_mpIgnoreWinConditions = null;
ConVar _conVar_svVoteIssueChangelevelAllowed = null;
Database _database = null;
Handle _forceRespawnHandle = INVALID_HANDLE;
int _normalBotQuota = 0;

int _currentGameState = GAME_STATE_NOTHING;
int _currentVoteType = VOTE_TYPE_NONE;
int _lastMapChangeTimestamp = 0;
char _playerAuthIdInfo[MAXPLAYERS + 1][35];
int _playerCount = 0;
int _playerTeamInfo[MAXPLAYERS + 1] = { -1, ... };
int _team1GameWins = 0; // This team joined as insurgents.
int _team2GameWins = 0; // This team joined as security.
int _teamGameWinsRequired = 0;

// TODO:
// Disable voting on maps and stuff
// Respawn mode while match not in progress
// Voting to start match ()
// Tracking match results
// Enforce no team swapping while match in progress
// Point system?
// Unlock server if empty or game is too long.
// Pause playerstats while match not in progress.

public Plugin myinfo =
{
	name = "Tournament Helper",
	author = "Tollski",
	description = "",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

//
// Forwards
//

public void OnPluginStart()
{
	CreateConVar("sm_tournamenthelper_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	AddCommandListener(Command_Jointeam, "jointeam");

	HookEvent("game_end", Event_GameEnd);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_team", Event_PlayerTeam);

	RegAdminCmd("sm_endmatch", Command_EndMatch, ADMFLAG_GENERIC, "Ends match.");
	RegAdminCmd("sm_printstate", Command_PrintState, ADMFLAG_GENERIC, "Prints state.");

	RegConsoleCmd("sm_startvote", Command_StartVote, "Starts the voting process.");

	ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
	mpTeamsUnbalanceLimitConVar.IntValue = 0;

	_conVar_insBotQuota = FindConVar("ins_bot_quota");
	_conVar_mpIgnoreWinConditions = FindConVar("mp_ignore_win_conditions");
	_conVar_svVoteIssueChangelevelAllowed = FindConVar("sv_vote_issue_changelevel_allowed");

	// Respawn logic taken from https://github.com/jaredballou/insurgency-sourcemod/blob/master/scripting/disabled/respawn.sp
	GameData gameData = LoadGameConfigFile("plugin.respawn");
	if (gameData == INVALID_HANDLE) {
		SetFailState("[Tournament Helper] Fatal Error: Missing File \"plugin.respawn\"!");
	}

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, "ForceRespawn");
	_forceRespawnHandle = EndPrepSDKCall();

	ConnectToDatabase();
}

public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	if (_currentGameState == GAME_STATE_NOTHING)
	{
		return;
	}

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (client == i)
		{
			continue;
		}

		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			return;
		}
	}

	// PrintToServer("[Tournament Helper] All players disconnected. Ending match and voting.");
	// SetGameState(GAME_STATE_NOTHING);
}

public void OnClientPostAdminCheck(int client)
{
	int timeSinceLastMapChange = GetTime() - _lastMapChangeTimestamp;
	if (IsFakeClient(client) || _currentGameState == GAME_STATE_NOTHING || timeSinceLastMapChange < 60)
	{
		return;
	}
	
	int playersConnected = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			playersConnected++;
		}
	}

	if (playersConnected == 1) 
	{
		PrintToServer("[Tournament Helper] A player connected. Ensuring game state set to nothing.");
		SetGameState(GAME_STATE_NOTHING);
	}
}

public void OnConfigsExecuted()
{
	_normalBotQuota = _conVar_insBotQuota.IntValue;

	LoadState();
}

public void OnMapEnd()
{
	_lastMapChangeTimestamp = GetTime();
	SaveState();
}

public Action Command_EndMatch(int client, int args)
{
	if (args > 0) {
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Usage: sm_endmatch");
		return Plugin_Handled;
	}

	if (_currentGameState != GAME_STATE_MATCH_STARTING && _currentGameState != GAME_STATE_MATCH_IN_PROGRESS)
	{
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Failed to end match; no match is in progress.");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Tournament Helper] Ending match.");
	SetGameState(GAME_STATE_NOTHING);
	return Plugin_Handled;
}

public Action Command_PrintState(int client, int args)
{
	if (args > 0) {
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Usage: sm_printstate");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Tournament Helper] Printing current state.");
	
	ReplyToCommand(client, "[Tournament Helper] conVar_insBotQuota_value: %d, conVar_mpIgnoreWinConditions_value: %d, conVar_svVoteIssueChangelevelAllowed_value: %d",
	_conVar_insBotQuota.IntValue, _conVar_mpIgnoreWinConditions.IntValue, _conVar_svVoteIssueChangelevelAllowed.IntValue);
	ReplyToCommand(client, "[Tournament Helper] currentGameState: %d, currentVoteType: %d, playerCount: %d, team1GameWins: %d, team2GameWins: %d, teamGameWinsRequired: %d",
	_currentGameState, _currentVoteType, _playerCount, _team1GameWins, _team2GameWins, _teamGameWinsRequired);

	for (int i = 0; i < _playerCount; i++)
	{
		ReplyToCommand(client, "[Tournament Helper] player[%d] team: %d, authId: %s", i, _playerTeamInfo[i], _playerAuthIdInfo[i]);
	}

	return Plugin_Handled;
}

public Action Command_Jointeam(int client, const char[] command, int args)
{
	char team[8];
	GetCmdArg(1, team, sizeof(team));
	int iTeam = StringToInt(team);

	// PrintToChat(client, "command %s, team %d", command, iTeam);

	if (_currentGameState != GAME_STATE_NOTHING)
	{
		int allowedTeam = GetPlayerAllowedTeam(client);

		// PrintToChat(client, "_playerCount %d, allowedTeam %d", _playerCount, allowedTeam);

		if (allowedTeam != iTeam)
		{
			PrintToChat(client, "\x07e50000[Tournament Helper] You cannot currently join that team, the teams are locked.");
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
} 

public Action Command_StartVote(int client, int args)
{
	if (args > 0) {
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Usage: sm_startvote");
		return Plugin_Handled;
	}

	// if (_isMatchInProgress)
	
	if (_currentGameState == GAME_STATE_VOTING || IsVoteInProgress())
	{
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Failed to start vote; another vote is already in progress.");
		return Plugin_Handled;
	}

	int currentPlayersOnInsurgents = GetPlayerCountOnTeam(3);
	int currentPlayersOnSecurity = GetPlayerCountOnTeam(2);
	if (currentPlayersOnSecurity == 0 || currentPlayersOnInsurgents == 0)
	{
		// ReplyToCommand(client, "[Tournament Helper] Failed to start vote; both teams must have players.");
		// return Plugin_Handled;
	}

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	if (StartVote(1, pack) == 0)
	{
		ReplyToCommand(client, "\x05[Tournament Helper] Vote started.");
	}
	else
	{
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Failed to start vote due to an unexpected error.");
	}

	return Plugin_Handled;
}

//
// Hooks
//

public void Event_GameEnd(Event event, const char[] name, bool dontBroadcast)
{
	int team1Score = event.GetInt("team1_score");
	int team2Score = event.GetInt("team2_score");
	int winner = event.GetInt("winner");
	PrintToChatAll("game_end. team1_score: %d, team2_score: %d, winner: %d", team1Score, team2Score, winner);

	if (_currentGameState != GAME_STATE_MATCH_IN_PROGRESS)
	{
		return;
	}

	if (winner == 3)
	{
		_team1GameWins++;
	}
	else if (winner == 2)
	{
		_team2GameWins++;
	}

	if (_team1GameWins == _teamGameWinsRequired)
	{
		PrintToChatAll("Team 1 is the winner.");
		SetGameState(GAME_STATE_NOTHING);
	}
	if (_team2GameWins == _teamGameWinsRequired)
	{
		PrintToChatAll("Team 2 is the winner.");
		SetGameState(GAME_STATE_NOTHING);
	}
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{	
	// int customkill = event.GetInt("customkill");
	// int attackerTeam = event.GetInt("attackerteam");
	// int victimTeam = event.GetInt("team");
	// int attackerUserid = event.GetInt("attacker");
	// int assister = event.GetInt("assister");
	// int damagebits = event.GetInt("damagebits");
	// int deathflags = event.GetInt("deathflags");
	// int lives = event.GetInt("lives");
	// int priority = event.GetInt("priority");
	// char weapon[64];
	// event.GetString("weapon", weapon, sizeof(weapon));
	// int weaponid = event.GetInt("weaponid");
	// float x = event.GetFloat("x");
	// float y = event.GetFloat("y");
	// float z = event.GetFloat("z");
	// PrintToChatAll("\x05player_death. attackerUserid: %d, victimUserid: %d, attackerTeam: %d, victimTeam: %d, assister: %d, damagebits: %d, deathflags: %d, lives: %d, priority: %d, weapon: %s, weaponid: %d, x: %d, y: %d, z: %d",
	// 	attackerClient, victimUserid, attackerTeam, victimTeam, assister, damagebits, deathflags, lives, priority, weapon, weaponid, x, y ,z);

	int victimUserid = event.GetInt("userid");
	int victimClient = GetClientOfUserId(victimUserid);

	if (_currentGameState != GAME_STATE_MATCH_STARTING && _currentGameState != GAME_STATE_MATCH_IN_PROGRESS)
	{
		DataPack pack = new DataPack();
		pack.WriteCell(victimClient);
		CreateTimer(3.00, PlayerTeamEvent_Respawn_AfterDelay, pack);
	}
}

public Action PlayerTeamEvent_Respawn_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	CloseHandle(inputPack);

	// TODO: Verify player is dead and has a "class".

	PrintToChat(client, "[Tournament Helper] No match is in progress; respawning.");
	
	SDKCall(_forceRespawnHandle, client);

	return Plugin_Stop;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	// int oldteam = event.GetInt("oldteam");
	
	// PrintToChatAll("Player Team Event. userid: %d, team: %d, oldteam: %d.", userid, team, oldteam);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client) || _currentGameState == GAME_STATE_NOTHING)
	{
		return;
	}

	int allowedTeam = GetPlayerAllowedTeam(client);
	if (allowedTeam != team)
	{
		DataPack pack = new DataPack();
		pack.WriteCell(client);
		pack.WriteCell(allowedTeam);
		CreateTimer(0.25, PlayerTeamEvent_ChangeClientTeam_AfterDelay, pack);
	}
}

public Action PlayerTeamEvent_ChangeClientTeam_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	int allowedTeam = inputPack.ReadCell();
	CloseHandle(inputPack);

	PrintToChat(client, "\x07e50000[Tournament Helper] You are being moved to your designated team, the teams are locked.");
	ChangeClientTeam(client, allowedTeam);

	return Plugin_Stop;
}

//
// Helper Functions
//

public int GetPlayerAllowedTeam(int playerClient)
{
	char authId[35];
	GetClientAuthId(playerClient, AuthId_Steam2, authId, sizeof(authId));

	for (int i = 0; i < _playerCount; i++)
	{
		if (StrEqual(authId, _playerAuthIdInfo[i]))
		{
			return _playerTeamInfo[i];
		}
	}

	return -1;
}

public int GetPlayerCountOnEitherTeam()
{
	return GetPlayerCountOnTeam(2) + GetPlayerCountOnTeam(3);
}

public int GetPlayerCountOnTeam(int team)
{
	int count = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
		{
			count++;
		}
	}

	return count;
}

public void SetGameState(int gameState)
{
	if (gameState == _currentGameState)
	{
		return;
	}

	if (gameState == GAME_STATE_VOTING && _currentGameState != GAME_STATE_NOTHING)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'Voting'. This should not happen!");
		return;
	}
	if (gameState == GAME_STATE_MATCH_STARTING && _currentGameState != GAME_STATE_VOTING)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'MatchStarting'. This should not happen!");
		return;
	}
	if (gameState == GAME_STATE_MATCH_IN_PROGRESS && _currentGameState != GAME_STATE_MATCH_STARTING)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'MatchInProgress'. This should not happen!");
		return;
	}

	int previousGameState = _currentGameState;
	_currentGameState = gameState;

	PrintToServer("[Tournament Helper] Setting game state to %d.", _currentGameState);

	if (_currentGameState == GAME_STATE_NOTHING)
	{
		if (previousGameState == GAME_STATE_MATCH_STARTING || previousGameState == GAME_STATE_MATCH_IN_PROGRESS)
		{
			PrintToChatAll("\x07f5bf03[Tournament Helper] Match has been cancelled. Teams are now unlocked.");
		}
		else if (previousGameState == GAME_STATE_VOTING)
		{
			PrintToChatAll("\x07f5bf03[Tournament Helper] Voting has been cancelled. Teams are now unlocked.");
		}

		_currentVoteType = VOTE_TYPE_NONE;

		_conVar_insBotQuota.IntValue = _normalBotQuota;
		_conVar_mpIgnoreWinConditions.IntValue = 1;
		_conVar_svVoteIssueChangelevelAllowed.IntValue = 1;

		return;
	}

	if (_currentGameState == GAME_STATE_VOTING)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Voting is in progress. Teams are now locked.");
	
		_playerCount = 0;
		for (int i = 1; i < MaxClients + 1; i++)
		{
			_playerAuthIdInfo[i] = "";
			_playerTeamInfo[i] = -1;

			if (IsClientInGame(i) && !IsFakeClient(i))
			{
				char authId[35];
				GetClientAuthId(i, AuthId_Steam2, authId, sizeof(authId));
				
				_playerAuthIdInfo[_playerCount] = authId;
				_playerTeamInfo[_playerCount] = GetClientTeam(i);

				_playerCount++;
			}
		}

		return;
	}
	
	if (_currentGameState == GAME_STATE_MATCH_STARTING)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Match is starting...");

		_conVar_insBotQuota.IntValue = 0;

		return;
	}

	if (_currentGameState == GAME_STATE_MATCH_IN_PROGRESS)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Match is now in progress...");

		_conVar_mpIgnoreWinConditions.IntValue = 0;		
		_conVar_svVoteIssueChangelevelAllowed.IntValue = 0;

		_team1GameWins = 0;
		_team2GameWins = 0;

		return;
	}

	PrintToChatAll("\x07e50000[Tournament Helper] Unsupported game state '%d'. This should not happen!", _currentGameState);
}

// Vote Helper Functions

public int Handle_VoteMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		// This is called after VoteEnd.
		delete menu;
	}
	else if (action == MenuAction_VoteCancel)
	{
		PrintToChatAll("[Tournament Helper] No votes were cast; cancelling voting.");
		SetGameState(GAME_STATE_NOTHING);
	}
}
 
public void Handle_VoteResults(
	Menu menu, 
  int num_votes, 
  int num_clients, 
  const int[][] client_info, 
  int num_items, 
  const int[][] item_info)
{
	if (_currentVoteType == VOTE_TYPE_READY)
	{
		int yesItemIndex = GetMenuItemIndex(menu, num_items, item_info, "yes");

		// Verify yes from each player on a team.
		for (int i = 0; i < _playerCount; i++)
		{
			if (_playerTeamInfo[i] != 2 && _playerTeamInfo[i] != 3)
			{
				continue;
			}

			// Get vote for player.
			int playerVoteItemIndex = GetPlayerVoteItemIndex(menu, num_clients, client_info, _playerAuthIdInfo[i]);

			if (playerVoteItemIndex < 0 || playerVoteItemIndex != yesItemIndex)
			{
				SetGameState(GAME_STATE_NOTHING);
				return;
			}
		}

		PrintToChatAll("\x07f5bf03[Tournament Helper] All players are ready.");
		StartVote(VOTE_TYPE_WINCOUNT, null);
	}
	else if (_currentVoteType == VOTE_TYPE_WINCOUNT)
	{
		int insurgentsVotedItemIndex = GetTeamVoteItemIndex(menu, num_clients, client_info, 3);
		int securityVotedItemIndex = GetTeamVoteItemIndex(menu, num_clients, client_info, 2);
		if (insurgentsVotedItemIndex < 0 || securityVotedItemIndex < 0 || insurgentsVotedItemIndex != securityVotedItemIndex)
		{
			if (insurgentsVotedItemIndex < 0)
			{
				PrintToChatAll("[Tournament Helper] Insurgents team did not have a majority vote on any option.");	
			}
			if (securityVotedItemIndex < 0)
			{
				PrintToChatAll("[Tournament Helper] Security team did not have a majority vote on any option.");	
			}

			if (insurgentsVotedItemIndex >= 0 && securityVotedItemIndex >= 0)
			{
				PrintToChatAll("[Tournament Helper] Teams did not agree on an option.");	
			}

			StartVote(VOTE_TYPE_WINCOUNT, null);
			return;
		}

		char item[64];
		menu.GetItem(insurgentsVotedItemIndex, item, sizeof(item));
		PrintToChatAll("\x07f5bf03[Tournament Helper] Game wins required to win match: %s.", item);
		_teamGameWinsRequired = StringToInt(item);

		SetGameState(GAME_STATE_MATCH_STARTING);
	}
	else
	{
		PrintToChatAll("\x07e50000[Tournament Helper] VoteType %d not supported. This should not happen!", _currentVoteType);
		SetGameState(GAME_STATE_NOTHING);
	}
}

public int GetMenuItemIndex(
	Menu menu,
	int num_items, 
  const int[][] item_info,
	const char[] itemName)
{
	for (int i = 0; i < num_items; i++)
	{
		char item[64];
		menu.GetItem(item_info[i][VOTEINFO_ITEM_INDEX], item, sizeof(item));
		if (StrEqual(item, itemName))
		{
			return item_info[i][VOTEINFO_ITEM_INDEX];
		}
	}

	return -1;
}

public int GetPlayerVoteItemIndex(
	Menu menu,
	int num_clients, 
  const int[][] client_info,
	const char[] playerAuthId)
{
	for (int i = 0; i < num_clients; i++)
	{
		char authId[35];
		GetClientAuthId(client_info[i][VOTEINFO_CLIENT_INDEX], AuthId_Steam2, authId, sizeof(authId));

		if (StrEqual(authId, playerAuthId))
		{
			char playerName[64];
			GetClientName(client_info[i][VOTEINFO_CLIENT_INDEX], playerName, sizeof(playerName));
			char item[64];
			menu.GetItem(client_info[i][VOTEINFO_CLIENT_ITEM], item, sizeof(item));
			PrintToChatAll("[Tournament Helper] %s voted %s", playerName, item);

			return client_info[i][VOTEINFO_CLIENT_ITEM];
		}
	}

	return -2;
}

public int GetTeamVoteItemIndex(
	Menu menu,
	int num_clients, 
  const int[][] client_info,
	int team)
{
	int maxItemIndex = -1;
	for (int i = 0; i < num_clients; i++)
	{
		if (client_info[i][VOTEINFO_CLIENT_ITEM] > maxItemIndex)
		{
			maxItemIndex = client_info[i][VOTEINFO_CLIENT_ITEM];
		}
	}

	if (maxItemIndex < 0) {
		return -3;
	}

	int teamVoteCountTotal = 0;
	int[] teamVoteCountByItem = new int[maxItemIndex + 1];
	for (int i = 0; i < _playerCount; i++)
	{
		if (_playerTeamInfo[i] != team)
		{
			continue;
		}

		int playerVoteItemIndex = GetPlayerVoteItemIndex(menu, num_clients, client_info, _playerAuthIdInfo[i]);
		teamVoteCountByItem[playerVoteItemIndex]++;
		teamVoteCountTotal++;
	}

	for (int i = 0; i < maxItemIndex + 1; i++)
	{
		if ((teamVoteCountByItem[i] / float(teamVoteCountTotal)) > 0.5)
		{
			return i;
		}
	}

	return -team;
}

int _countdownTimeRemaining = 0;
Handle _countdownTimeRemainingHandle = null;
public void ShowCountdownTimer(int seconds)
{
	if (_countdownTimeRemainingHandle != null)
	{
		KillTimer(_countdownTimeRemainingHandle);
	}

	PrintCenterTextAll("Time remaining for current vote: %ds", seconds);

	_countdownTimeRemaining = seconds - 1;
	_countdownTimeRemainingHandle = CreateTimer(1.0, ShowCountdownTimer_AfterDelay, _, TIMER_REPEAT);
}

public Action ShowCountdownTimer_AfterDelay(Handle timer)
{
	if (_countdownTimeRemaining <= 0)
	{
		_countdownTimeRemainingHandle = null;
		return Plugin_Stop;
	}

	PrintCenterTextAll("Time remaining for current vote: %ds", _countdownTimeRemaining);

	_countdownTimeRemaining--;
	return Plugin_Continue;
}

public int StartVote(int voteType, DataPack inputPack)
{
	if (_currentVoteType != voteType - 1 && _currentVoteType != voteType)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot start vote type %d when current vote type is %d.", voteType, _currentVoteType);
		return 1;
	}

	Menu menu = new Menu(Handle_VoteMenu);
	menu.ExitButton = false;
	menu.VoteResultCallback = Handle_VoteResults;

	if (voteType == VOTE_TYPE_READY)
	{
		StartVoteHelper_PopulateReadyMenu(menu, inputPack);
		SetGameState(GAME_STATE_VOTING);
	}
	else if (voteType == VOTE_TYPE_WINCOUNT)
	{
		StartVoteHelper_PopulateWinCountMenu(menu);
	}
	else
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Unsupported vote type '%d'.", voteType);
		return 1;
	}
	
	_currentVoteType = voteType;

	ShowCountdownTimer(30);
	menu.DisplayVoteToAll(30);

	return 0;
}

Handle _mapArray = null;
int mapSerial = -1;

public int StartVoteHelper_PopulateWinCountMenu(Menu menu)
{
	menu.SetTitle("Select amount of game wins required to win the match.");
	menu.AddItem("1", "Best 1 out of 1 maps.");
	menu.AddItem("2", "Best 2 out of 3 maps.");
}

public int StartVoteHelper_PopulateMapMenu(Menu menu)
{
	// This will populate the menu with all the maps in the map cycle, but it has no data on gamemodes.
	// Until voting on game modes is figured out, it's probably best to just leverage the in-game map voting.

	Handle mapArray = ReadMapList(
		_mapArray,
		mapSerial,
		"default",
		MAPLIST_FLAG_CLEARARRAY|MAPLIST_FLAG_MAPSFOLDER);

	if (mapArray != null)
	{
		_mapArray = mapArray;
	}

	if (_mapArray == null)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Map array is null.");
		return 1;
	}

	menu.SetTitle("Select a map.");
	
	int mapCount = GetArraySize(_mapArray);
	for (int i = 0; i < mapCount; i++)
	{
		char mapName[PLATFORM_MAX_PATH];
		GetArrayString(_mapArray, i, mapName, sizeof(mapName));

		char mapDisplayName[PLATFORM_MAX_PATH];
		GetMapDisplayName(mapName, mapDisplayName, sizeof(mapDisplayName));

		PrintToChatAll("(%d) '%s': '%s'", i, mapName, mapDisplayName);

		menu.AddItem(mapName, mapDisplayName);
	}

	return 0;
}

public int StartVoteHelper_PopulateReadyMenu(Menu menu, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	CloseHandle(inputPack);

	char requestorName[MAX_NAME_LENGTH];
	GetClientName(client, requestorName, sizeof(requestorName));

	menu.SetTitle("'%s' has initiated a vote to start the match. Is your team ready?", requestorName);
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
}

// Database Functions

public void ConnectToDatabase()
{
	char error[256];
	_database = SQLite_UseDatabase("tournamenthelper", error, sizeof(error));
	if (_database == INVALID_HANDLE)
	{
		SetFailState("Failed to connect to the database 'tournamenthelper' with error: '%s'", error);
		return;
	}

	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_state (key VARCHAR(64) PRIMARY KEY, value Int(11) NOT NULL)");
	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_playerAuthIdInfo (i Int(3) PRIMARY KEY, value VARCHAR(35) NOT NULL)");
	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_playerTeamInfo (i Int(3) PRIMARY KEY, value Int(2) NOT NULL)");
}

public void SaveState()
{
	char queryString[512];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"REPLACE INTO th_state (key, value) VALUES ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d)",
		"conVar_insBotQuota_value", _conVar_insBotQuota.IntValue, "conVar_mpIgnoreWinConditions_value", _conVar_mpIgnoreWinConditions.IntValue, "conVar_svVoteIssueChangelevelAllowed_value", _conVar_svVoteIssueChangelevelAllowed.IntValue,
		"currentGameState", _currentGameState, "currentVoteType", _currentVoteType, "lastMapChangeTimestamp", _lastMapChangeTimestamp, "playerCount", _playerCount, "team1GameWins", _team1GameWins, "team2GameWins", _team2GameWins, "teamGameWinsRequired", _teamGameWinsRequired);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	SQL_TQuery(_database, SqlQueryCallback_SaveState1, "DELETE FROM th_playerAuthIdInfo");
	SQL_TQuery(_database, SqlQueryCallback_SaveState2, "DELETE FROM th_playerTeamInfo");
}

public void SqlQueryCallback_SaveState1(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_SaveState1: '%s'", sError);
	}

	for (int i = 0; i < _playerCount; i++)
	{			
		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "INSERT INTO th_playerAuthIdInfo (i, value) VALUES (%d, '%s')", i, _playerAuthIdInfo[i]);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}
}

public void SqlQueryCallback_SaveState2(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_SaveState2: '%s'", sError);
	}

	for (int i = 0; i < _playerCount; i++)
	{			
		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "INSERT INTO th_playerTeamInfo (i, value) VALUES (%d, %d)", i, _playerTeamInfo[i]);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}
}

public void LoadState()
{
	char queryString1[256];
	SQL_FormatQuery(_database, queryString1, sizeof(queryString1), "SELECT * FROM th_state");
	SQL_TQuery(_database, SqlQueryCallback_LoadState1, queryString1);

	char queryString2[256];
	SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "SELECT * FROM th_playerAuthIdInfo");
	SQL_TQuery(_database, SqlQueryCallback_LoadState2, queryString2);

	char queryString3[256];
	SQL_FormatQuery(_database, queryString3, sizeof(queryString3), "SELECT * FROM th_playerTeamInfo");
	SQL_TQuery(_database, SqlQueryCallback_LoadState3, queryString3);
}

public void SqlQueryCallback_LoadState1(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_LoadState1: '%s'", sError);
	}

	while (SQL_FetchRow(handle))
	{
		char key[64];
		SQL_FetchString(handle, 0, key, sizeof(key));
		int value = SQL_FetchInt(handle, 1);

		if (StrEqual(key, "conVar_insBotQuota_value"))
		{
			_conVar_insBotQuota.IntValue = value;
		}
		else if (StrEqual(key, "conVar_mpIgnoreWinConditions_value"))
		{
			_conVar_mpIgnoreWinConditions.IntValue = value;
		}
		else if (StrEqual(key, "conVar_svVoteIssueChangelevelAllowed_value"))
		{
			_conVar_svVoteIssueChangelevelAllowed.IntValue = value;
		}
		else if (StrEqual(key, "currentGameState"))
		{
			_currentGameState = value;
		}
		else if (StrEqual(key, "currentVoteType"))
		{
			_currentVoteType = value;
		}
		else if (StrEqual(key, "_lastMapChangeTimestamp"))
		{
			_lastMapChangeTimestamp = value;
		}
		else if (StrEqual(key, "playerCount"))
		{
			_playerCount = value;
		}
		else if (StrEqual(key, "team1GameWins"))
		{
			_team1GameWins = value;
		}
		else if (StrEqual(key, "team2GameWins"))
		{
			_team2GameWins = value;
		}
		else if (StrEqual(key, "teamGameWinsRequired"))
		{
			_teamGameWinsRequired = value;
		}
	}

	if (_currentGameState == GAME_STATE_MATCH_STARTING)
	{
		SetGameState(GAME_STATE_MATCH_IN_PROGRESS);
	}
}

public void SqlQueryCallback_LoadState2(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_LoadState2: '%s'", sError);
	}

	while (SQL_FetchRow(handle))
	{
		int i = SQL_FetchInt(handle, 0);
		char value[35];
		SQL_FetchString(handle, 1, value, sizeof(value));

		_playerAuthIdInfo[i] = value;
	}
}

public void SqlQueryCallback_LoadState3(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_LoadState3: '%s'", sError);
	}

	while (SQL_FetchRow(handle))
	{
		int i = SQL_FetchInt(handle, 0);
		int value = SQL_FetchInt(handle, 1);

		_playerTeamInfo[i] = value;
	}
}

public void SqlQueryCallback_Default(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Default: %d, '%s'", data, sError);
	}
}