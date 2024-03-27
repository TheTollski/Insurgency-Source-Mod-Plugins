#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

const int GAME_STATE_NOTHING = 1;
const int GAME_STATE_VOTING = 2;
const int GAME_STATE_MATCH = 3;

bool _currentGameState = GAME_STATE_NOTHING;
int _currentVoteType = -1; // 1 = Ready
Handle _forceRespawnHandle = INVALID_HANDLE;
int _normalBotQuota = -1;
char _playerAuthIdInfo[MAXPLAYERS + 1][35];
int _playerCount = -1;
int _playerTeamInfo[MAXPLAYERS + 1] = { -1, ... };

// TODO:
// Disable voting on maps and stuff
// Respawn mode while match not in progress
// Voting to start match ()
// Tracking match results
// Enforce no team swapping while match in progress
// Point system?
// Unlock server if empty or game is too long.

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

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_team", Event_PlayerTeam);

	RegAdminCmd("sm_endmatch", Command_EndMatch, ADMFLAG_GENERIC, "Ends match.");

	RegConsoleCmd("sm_startvote", Command_StartVote, "Starts the voting process.");

	GameData gameData = LoadGameConfigFile("plugin.respawn");
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, "ForceRespawn");
	_forceRespawnHandle = EndPrepSDKCall();
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

	PrintToServer("All players disconnected. Ending match and voting.");
	SetGameState(GAME_STATE_NOTHING);
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client) || _currentGameState == GAME_STATE_NOTHING)
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
		PrintToServer("A player connected. Ensuring game state set to nothing.");
		SetGameState(GAME_STATE_NOTHING);
	}
}

public void OnMapStart()
{

}

public Action Command_EndMatch(int client, int args)
{
	if (args > 0) {
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Usage: sm_endmatch");
		return Plugin_Handled;
	}

	if (_currentGameState != GAME_STATE_MATCH)
	{
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Failed to end match; no match is in progress.");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Tournament Helper] Ending match.");
	SetGameState(GAME_STATE_NOTHING);
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

	ReplyToCommand(client, "\x05[Tournament Helper] Initiating vote.");

	char requestorName[MAX_NAME_LENGTH];
	GetClientName(client, requestorName, sizeof(requestorName));

	SetGameState(GAME_STATE_VOTING);
	_currentVoteType = 1;

	Menu menu = new Menu(Handle_VoteMenu);
	menu.VoteResultCallback = Handle_VoteResults;
	menu.SetTitle("'%s' has initiated a vote to start the match. Is your team ready?", requestorName);
	// menu.SetTitle("Change map to: %s?", map);
	// menu.AddItem(map, "Yes");
	// menu.AddItem("no", "No");
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = false;
	menu.DisplayVoteToAll(10);

	return Plugin_Handled;
}

//
// Hooks
//

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int customkill = event.GetInt("customkill");

	int attackerTeam = event.GetInt("attackerteam");
	int victimTeam = event.GetInt("team");
	
	int attackerUserid = event.GetInt("attacker");
	int victimUserid = event.GetInt("userid");

	int attackerClient = GetClientOfUserId(attackerUserid);
	int victimClient = GetClientOfUserId(victimUserid);

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

	if (_currentGameState != GAME_STATE_MATCH)
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

	PrintToChat(client, "[Tournament Helper] No match is in progress; respawning.");
	
	SDKCall(_forceRespawnHandle, client);
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

	if (gameState == GAME_STATE_MATCH && _currentGameState == GAME_STATE_NOTHING)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'MatchInProgress'. This should not happen!");
		return;
	}
	if (gameState == GAME_STATE_VOTING && _currentGameState == GAME_STATE_MATCH)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'VotingInProgress'. This should not happen!");
		return;
	}

	int previousGameState = _currentGameState;
	_currentGameState = gameState;

	PrintToServer("[Tournament Helper] Setting game state to %d.", _currentGameState);

	if (_currentGameState == GAME_STATE_NOTHING)
	{
		if (previousGameState == GAME_STATE_MATCH)
		{
			PrintToChatAll("\x07f5bf03[Tournament Helper] Match has been cancelled. Teams are now unlocked.");
		}
		else if (previousGameState == GAME_STATE_VOTING)
		{
			PrintToChatAll("\x07f5bf03[Tournament Helper] Voting has been cancelled. Teams are now unlocked.");
		}

		ConVar insBotQuotaConVar = FindConVar("ins_bot_quota");
		insBotQuotaConVar.IntValue = _normalBotQuota;

		ConVar mpIgnoreWinConditionsConVar = FindConVar("mp_ignore_win_conditions");
		mpIgnoreWinConditionsConVar.IntValue = 1;

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
	
	if (_currentGameState == GAME_STATE_MATCH)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Match is starting...");

		ConVar insBotQuotaConVar = FindConVar("ins_bot_quota");
		_normalBotQuota = insBotQuotaConVar.IntValue;
		insBotQuotaConVar.IntValue = 0;

		ConVar mpIgnoreWinConditionsConVar = FindConVar("mp_ignore_win_conditions");
		mpIgnoreWinConditionsConVar.IntValue = 0;

		// Reload map?
		return;
	}

	PrintToChatAll("\x07e50000[Tournament Helper] Unsupported game state '%d'. This should not happen!", _currentGameState);
}

// Vote Helper Functions

public int Handle_VoteMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		/* This is called after VoteEnd */
		delete menu;
	}
	else if (action == MenuAction_VoteCancel)
	{
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
	/* See if there were multiple winners */
	// int winner = 0;
	// if (num_items > 1 && (item_info[0][VOTEINFO_ITEM_VOTES] == item_info[1][VOTEINFO_ITEM_VOTES]))
	// {
	//   winner = GetRandomInt(0, 1);
	// }

	// char map[64];
	// menu.GetItem(item_info[winner][VOTEINFO_ITEM_INDEX], map, sizeof(map));
	// ServerCommand("changelevel %s", map);


	// PrintToChatAll("[Tournament Helper] Handle_VoteResults. num_votes %d, num_clients %d, num_items %d", num_votes, num_clients, num_items);

	// for (int i = 0; i < num_clients; i++)
	// {
	// 	PrintToChatAll("[Tournament Helper] client[%d], index %d, item %d", i, client_info[i][VOTEINFO_CLIENT_INDEX], client_info[i][VOTEINFO_CLIENT_ITEM]);
	// }

	// for (int i = 0; i < num_items; i++)
	// {
	// 	char item[64];
	// 	menu.GetItem(item_info[i][VOTEINFO_ITEM_INDEX], item, sizeof(item));
	// 	PrintToChatAll("[Tournament Helper] item[%d], index %d, votes %d, value %s", i, item_info[i][VOTEINFO_ITEM_INDEX], item_info[i][VOTEINFO_ITEM_VOTES], item);
	// }

	if (_currentVoteType == 1) // Ready Vote
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

		SetGameState(GAME_STATE_MATCH);
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
