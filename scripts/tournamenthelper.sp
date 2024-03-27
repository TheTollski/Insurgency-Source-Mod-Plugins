// Note: "plugin.respawn.txt" must be added to the server's "insurgency/addons/sourcemod/gamedata" directory.

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

const int GAME_STATE_NONE = 0;
const int GAME_STATE_IDLE = 1;
const int GAME_STATE_VOTING = 2;
const int GAME_STATE_MATCH_READY = 3;
const int GAME_STATE_MATCH_IN_PROGRESS = 4;

const int VOTE_TYPE_NONE = 0;
const int VOTE_TYPE_READY = 1;
const int VOTE_TYPE_GAMEWINCOUNT = 2;
const int VOTE_TYPE_ROUNDWINCOUNT = 3;
const int VOTE_TYPE_GAME1MAPSELECTION = 4;
const int VOTE_TYPE_GAME1TEAMSELECTION = 5;
const int VOTE_TYPE_GAME2MAPSELECTION = 6;
const int VOTE_TYPE_GAME2TEAMSELECTION = 7;
const int VOTE_TYPE_GAME3MAPSELECTION = 8;

ConVar _conVar_insBotQuota = null;
ConVar _conVar_mpIgnoreTimerConditions = null;
ConVar _conVar_mpIgnoreWinConditions = null;
ConVar _conVar_mpMaxRounds = null;
ConVar _conVar_mpWinLimit = null;
ConVar _conVar_svVoteIssueChangelevelAllowed = null;
Database _database = null;
Handle _forceRespawnHandle = INVALID_HANDLE;
int _normalBotQuota = 0;

int _currentGameState = GAME_STATE_NONE;
int _currentVoteType = VOTE_TYPE_NONE;
int _lastMapChangeTimestamp = 0;
char _game1MapName[PLATFORM_MAX_PATH];
int _game1TeamATeam = 0;
char _game2MapName[PLATFORM_MAX_PATH];
int _game2TeamATeam = 0;
char _game3MapName[PLATFORM_MAX_PATH];
int _game3TeamATeam = 0;
int _matchId = 0;
char _playerAuthIdInfo[MAXPLAYERS + 1][35];
int _playerCount = 0;
bool _playerIsRespawnable[MAXPLAYERS + 1] = { false, ...};
int _playerTeamInfo[MAXPLAYERS + 1] = { -1, ... };
bool _pluginIsChangingMpMaxRounds = false;
bool _pluginIsChangingMpWinLimit = false;
int _teamAGameWins = 0; // This team joined as security.
int _teamBGameWins = 0; // This team joined as insurgents.
int _teamARoundWins = 0;
int _teamBRoundWins = 0;
int _teamGameWinsRequired = 0;
int _teamRoundWinsRequired = 0;

// TODO:
// Should players on no team allow ready vote to be called?
// Automatically change map when match is over, or print hint text.
// Allowing late players to join/swapping players in the middle of a match
// Ability to pause the game.
// Bug: Security left server and then Insurgents had to repick class.
// Remove bots as players join.
// Allow all players to join teams before starting first round of a game.
// simpleplayerstats should only capture stats during matches
// capture very basic stats to save to match history
// don't cancel vote if nobody votes (time limit + cancelvote command?)
// Any player voting not ready should cancel ready vote.

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
	// HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_team", Event_PlayerTeam);
	HookEvent("round_end", Event_RoundEnd);

	RegAdminCmd("sm_endmatch", Command_EndMatch, ADMFLAG_GENERIC, "Ends match.");
	RegAdminCmd("sm_printstate", Command_PrintState, ADMFLAG_GENERIC, "Prints state.");

	RegConsoleCmd("sm_matchhistory", Command_MatchHistory, "Prints match history.");
	RegConsoleCmd("sm_startvote", Command_StartVote, "Starts the voting process.");

	ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
	mpTeamsUnbalanceLimitConVar.IntValue = 0;

	_conVar_insBotQuota = FindConVar("ins_bot_quota");
	_conVar_mpIgnoreTimerConditions = FindConVar("mp_ignore_timer_conditions");
	_conVar_mpIgnoreWinConditions = FindConVar("mp_ignore_win_conditions");
	_conVar_mpMaxRounds = FindConVar("mp_maxrounds");
	_conVar_mpWinLimit = FindConVar("mp_winlimit");
	_conVar_svVoteIssueChangelevelAllowed = FindConVar("sv_vote_issue_changelevel_allowed");

	_conVar_mpMaxRounds.AddChangeHook(ConVarChanged_MpMaxRounds);
	_conVar_mpWinLimit.AddChangeHook(ConVarChanged_MpWinLimit);

	// Respawn logic taken from https://github.com/jaredballou/insurgency-sourcemod/blob/master/scripting/disabled/respawn.sp
	GameData gameData = LoadGameConfigFile("plugin.respawn");
	if (gameData == INVALID_HANDLE) {
		SetFailState("[Tournament Helper] Fatal Error: Missing File \"plugin.respawn\"!");
	}

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, "ForceRespawn");
	_forceRespawnHandle = EndPrepSDKCall();

	// Setup Damage Handler
	for (int i = 1; i < MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
			int team = GetClientTeam(i);
			if (team == 2 || team == 3)
			{
				_playerIsRespawnable[i] = true;
			}
		}
	}

	ConnectToDatabase();
}

public void OnClientAuthorized(int client, const char[] authId)
{
	if (_currentGameState == GAME_STATE_NONE || _currentGameState == GAME_STATE_IDLE)
	{
		return;
	}

	int otherConnectedPlayersCount = GetOtherConnectedPlayersCount(client);
	if (otherConnectedPlayersCount == 0) 
	{
		return;
	}

	for (int i = 0; i < _playerCount; i++)
	{
		if (StrEqual(authId, _playerAuthIdInfo[i]))
		{
			return;
		}
	}

	if (_currentGameState == GAME_STATE_VOTING)
	{
		KickClient(client, "Voting is in progress for a private match");
	}
	else
	{
		KickClient(client, "A private match is in progress");
	}
}

public void OnClientPostAdminCheck(int client)
{
	int timeSinceLastMapChange = GetTime() - _lastMapChangeTimestamp;
	if (IsFakeClient(client) || _currentGameState == GAME_STATE_IDLE || (_currentGameState == GAME_STATE_MATCH_IN_PROGRESS && timeSinceLastMapChange < 120))
	{
		return;
	}
	
	int otherConnectedPlayersCount = GetOtherConnectedPlayersCount(client);
	if (otherConnectedPlayersCount == 0) 
	{
		PrintToServer("[Tournament Helper] A player connected. Ensuring game state set to idle.");
		SetGameState(GAME_STATE_IDLE);
	}
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
	_playerIsRespawnable[client] = false;
}

public void OnConfigsExecuted()
{
	_normalBotQuota = _conVar_insBotQuota.IntValue;

	// I thought variables were wiped on map change, why do I need to do this?
	_teamARoundWins = 0;
	_teamBRoundWins = 0;

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

	if (_currentGameState != GAME_STATE_MATCH_READY && _currentGameState != GAME_STATE_MATCH_IN_PROGRESS)
	{
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Failed to end match; no match is in progress.");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Tournament Helper] Ending match.");
	SetGameState(GAME_STATE_IDLE);
	return Plugin_Handled;
}

public Action Command_PrintState(int client, int args)
{
	if (args > 0) {
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Usage: sm_printstate");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Tournament Helper] Printing current state.");
	
	ReplyToCommand(client, "[Tournament Helper] conVar_insBotQuota_value: %d, conVar_mpIgnoreTimerConditions_value: %d, conVar_mpIgnoreWinConditions_value: %d, conVar_svVoteIssueChangelevelAllowed_value: %d",
		_conVar_insBotQuota.IntValue, _conVar_mpIgnoreTimerConditions.IntValue, _conVar_mpIgnoreWinConditions.IntValue, _conVar_svVoteIssueChangelevelAllowed.IntValue);
	ReplyToCommand(client, "[Tournament Helper] currentGameState: %d, currentVoteType: %d, playerCount: %d, teamAGameWins: %d, teamBGameWins: %d, teamGameWinsRequired: %d",
		_currentGameState, _currentVoteType, _playerCount, _teamAGameWins, _teamBGameWins, _teamGameWinsRequired);
	ReplyToCommand(client, "[Tournament Helper] teamRoundWinsRequired: %d",
		_teamRoundWinsRequired);

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

	if (_currentGameState != GAME_STATE_IDLE)
	{
		int allowedTeam = GetPlayerAllowedTeam(client);

		// PrintToChat(client, "_playerCount %d, allowedTeam %d", _playerCount, allowedTeam);

		if (allowedTeam != iTeam)
		{
			PrintToChat(client, "\x07e50000[Tournament Helper] You cannot currently join that team, the teams are locked.");
			
			if (allowedTeam != GetClientTeam(client))
			{
				DataPack pack = new DataPack();
				pack.WriteCell(client);
				pack.WriteCell(allowedTeam);
				CreateTimer(0.25, ChangeClientTeam_AfterDelay, pack);
			}

			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

public Action Command_MatchHistory(int client, int args)
{
	if (args > 1)
	{
		ReplyToCommand(client, "\x05[Tournament Helper] Usage: sm_matchhistory [Page]");
		return Plugin_Handled;
	}

	char arg1[32];
	if (args >= 1)
	{
		GetCmdArg(1, arg1, sizeof(arg1));
	}
	else
	{
		arg1 = "1";
	}

	if (args == 0)
	{
		ReplyToCommand(client, "[Tournament Helper] Using defaults: sm_matchhistory 1");
	}

	int pageSize = 10;
	int page = StringToInt(arg1);
	int offset = (page - 1) * pageSize;

	ReplyToCommand(client, "\x05[Tournament Helper] Match history is being printed in the console.");

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM th_matches ORDER BY readyTimestamp DESC LIMIT %d OFFSET %d", pageSize, offset);
	SQL_TQuery(_database, SqlQueryCallback_Command_MatchHistory1, queryString, client);
	return Plugin_Handled;
}

public Action Command_StartVote(int client, int args)
{
	if (args > 0) {
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Usage: sm_startvote");
		return Plugin_Handled;
	}
	
	if (_currentGameState == GAME_STATE_VOTING || IsVoteInProgress())
	{
		ReplyToCommand(client, "\x07e50000[Tournament Helper] Failed to start vote; another vote is already in progress.");
		return Plugin_Handled;
	}

	int currentPlayersOnInsurgents = GetPlayerCountOnTeam(3);
	int currentPlayersOnSecurity = GetPlayerCountOnTeam(2);
	if (currentPlayersOnSecurity == 0 || currentPlayersOnInsurgents == 0)
	{
		ReplyToCommand(client, "[Tournament Helper] Failed to start vote; both teams must have players.");
		return Plugin_Handled;
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

public Action OnTakeDamage(int client, int &attacker, int &inflictor, float &damage, int &damageType, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	// PrintToChatAll("OnTakeDamage. client: %d, attacker: %d, inflictor: %d, dmg: %0.1f, damageType: %d, weapon: %d", client, attacker, inflictor, damage, damageType, weapon);

	if (_currentGameState == GAME_STATE_VOTING || _currentGameState == GAME_STATE_MATCH_READY)
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

//
// Hooks
//

public void ConVarChanged_MpMaxRounds(ConVar convar, char[] oldValue, char[] newValue)
{
	if (_pluginIsChangingMpMaxRounds)
	{
		return;
	}

	PrintToConsoleAll("[Tournament Helper] Reverting a server change to mp_maxrounds, setting to: %s", oldValue);
	ChangeMpMaxRounds(StringToInt(oldValue));
}

public void ConVarChanged_MpWinLimit(ConVar convar, char[] oldValue, char[] newValue)
{
	if (_pluginIsChangingMpWinLimit)
	{
		return;
	}

	PrintToConsoleAll("[Tournament Helper] Reverting a server change to mp_winlimit, setting to: %s", oldValue);
	ChangeMpWinLimit(StringToInt(oldValue));
}

public void Event_GameEnd(Event event, const char[] name, bool dontBroadcast)
{
	// int team1Score = event.GetInt("team1_score");
	// int team2Score = event.GetInt("team2_score");
	int winner = event.GetInt("winner");
	// PrintToChatAll("game_end. team1_score: %d, team2_score: %d, winner: %d", team1Score, team2Score, winner);

	if (_currentGameState != GAME_STATE_MATCH_IN_PROGRESS)
	{
		return;
	}

	char winningTeam;
	if (winner == GetTeamATeam())
	{
		_teamAGameWins++;
		winningTeam = 'A';

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE th_matches SET teamAGameWins = teamAGameWins + 1 WHERE id = %d", _matchId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}
	else if (winner == GetTeamBTeam())
	{
		_teamBGameWins++;
		winningTeam = 'B';

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE th_matches SET teamBGameWins = teamBGameWins + 1 WHERE id = %d", _matchId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}

	PrintToChatAll("\x07f5bf03[Tournament Helper] Team %c wins the game! Team A game wins: %d, team B game wins: %d, game wins required to win the match: %d.",
		winningTeam, _teamAGameWins, _teamBGameWins, _teamGameWinsRequired);

	char matchWinner;
	if (_teamAGameWins == _teamGameWinsRequired)
	{
		matchWinner = 'A';
		PrintToChatAll("\x07f5bf03[Tournament Helper] Team A wins the match!");
	}
	else if (_teamBGameWins == _teamGameWinsRequired)
	{
		matchWinner = 'B';
		PrintToChatAll("\x07f5bf03[Tournament Helper] Team B wins the match!");
	}

	if (matchWinner)
	{
		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE th_matches SET endTimestamp = %d, matchWinningTeam = '%c' WHERE id = %d", GetTime(), matchWinner, _matchId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		SetGameState(GAME_STATE_IDLE);
	}
	else
	{
		int gameNumber = _teamAGameWins + _teamBGameWins;
		if (gameNumber == 1)
		{
			ChangeMap(_game2MapName);
		}
		else
		{
			ChangeMap(_game3MapName);
		}
	}
}

// public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
// {	
// 	// int customkill = event.GetInt("customkill");
// 	// int attackerTeam = event.GetInt("attackerteam");
// 	// int victimTeam = event.GetInt("team");
// 	// int attackerUserid = event.GetInt("attacker");
// 	// int assister = event.GetInt("assister");
// 	// int damagebits = event.GetInt("damagebits");
// 	// int deathflags = event.GetInt("deathflags");
// 	// int lives = event.GetInt("lives");
// 	// int priority = event.GetInt("priority");
// 	// char weapon[64];
// 	// event.GetString("weapon", weapon, sizeof(weapon));
// 	// int weaponid = event.GetInt("weaponid");
// 	// float x = event.GetFloat("x");
// 	// float y = event.GetFloat("y");
// 	// float z = event.GetFloat("z");
// 	// PrintToChatAll("\x05player_death. attackerUserid: %d, victimUserid: %d, attackerTeam: %d, victimTeam: %d, assister: %d, damagebits: %d, deathflags: %d, lives: %d, priority: %d, weapon: %s, weaponid: %d, x: %d, y: %d, z: %d",
// 	// 	attackerClient, victimUserid, attackerTeam, victimTeam, assister, damagebits, deathflags, lives, priority, weapon, weaponid, x, y ,z);

// 	int victimUserid = event.GetInt("userid");
// 	int victimClient = GetClientOfUserId(victimUserid);

// 	if (_currentGameState != GAME_STATE_MATCH_READY && _currentGameState != GAME_STATE_MATCH_IN_PROGRESS)
// 	{
// 		DataPack pack = new DataPack();
// 		pack.WriteCell(victimClient);
// 		CreateTimer(1.00, PlayerTeamEvent_Respawn_AfterDelay, pack);
// 	}
// }

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	// int oldteam = event.GetInt("oldteam");
	
	// PrintToChatAll("player_team. userid: %d, team: %d, oldteam: %d.", userid, team, oldteam);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client))
	{
		return;
	}

	if (_currentGameState == GAME_STATE_IDLE)
	{
		_playerIsRespawnable[client] = false;

		DataPack pack = new DataPack();
		pack.WriteCell(client);
		CreateTimer(10.0, PlayerTeamEvent_SetIsRespawnable_AfterDelay, pack);
		return;
	}

	int allowedTeam = GetPlayerAllowedTeam(client);
	if (allowedTeam != team)
	{
		DataPack pack = new DataPack();
		pack.WriteCell(client);
		pack.WriteCell(allowedTeam);
		CreateTimer(0.25, ChangeClientTeam_AfterDelay, pack);
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	// int message = event.GetInt("message");
	// char messageString[64];
	// event.GetString("message_string", messageString, sizeof(messageString));
	// int reason = event.GetInt("reason");
	int winner = event.GetInt("winner");

	// PrintToChatAll("round_end. message: %d, messageString: %s, reason: %d, winner: %d", message, messageString, reason, winner);
	
	char winningTeam;
	if (winner == GetTeamATeam())
	{
		_teamARoundWins++;
		winningTeam = 'A';
	}
	else if (winner == GetTeamBTeam())
	{
		_teamBRoundWins++;
		winningTeam = 'B';
	}

	PrintToChatAll("\x07f5bf03[Tournament Helper] Team %c wins the round! Team A round wins: %d, team B round wins: %d, round wins required to win the game: %d.",
		winningTeam, _teamARoundWins, _teamBRoundWins, _teamRoundWinsRequired);
}

public Action PlayerTeamEvent_SetIsRespawnable_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	CloseHandle(inputPack);

	_playerIsRespawnable[client] = true;

	return Plugin_Stop;
}

public Action ChangeClientTeam_AfterDelay(Handle timer, DataPack inputPack)
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

public void ChangeMap(const char[] mapName)
{
	DataPack pack = new DataPack();
	pack.WriteString(mapName);
	CreateTimer(5.0, ChangeMap_AfterDelay, pack);

	ShowCountdownTimer(5, "Time remaining until map changes");
}

public Action ChangeMap_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	char mapName[256];
	inputPack.ReadString(mapName, sizeof(mapName));
	CloseHandle(inputPack);

	if (StrContains(mapName, "demolition") > -1)
	{
		PrintToConsoleAll("[Tournament Helper] Changing map to '%s skirmish'", mapName);
		ServerCommand("map %s skirmish", mapName);
	}
	else
	{
		PrintToConsoleAll("[Tournament Helper] Changing map to '%s firefight'", mapName);
		ServerCommand("map %s firefight", mapName);
	}

	return Plugin_Stop;
}

public void ChangeMpMaxRounds(int newValue)
{
	PrintToServer("[Tournament Helper] Changing mp_maxrounds to '%d'.", newValue);

	_pluginIsChangingMpMaxRounds = true;
	_conVar_mpMaxRounds.IntValue = newValue;
	_pluginIsChangingMpMaxRounds = false;
}

public void ChangeMpWinLimit(int newValue)
{
	PrintToServer("[Tournament Helper] Changing mp_winlimit to '%d'.", newValue);

	_pluginIsChangingMpWinLimit = true;
	_conVar_mpWinLimit.IntValue = newValue;
	_pluginIsChangingMpWinLimit = false;
}

public int ConvertTeamNameToInt(const char[] paramAuthId)
{
	if (StrEqual(paramAuthId, "security"))
	{
		return 2;
	}

	if (StrEqual(paramAuthId, "insurgents"))
	{
		return 3;
	}

	return -1;
}

public int GetClientFromAuthId(const char[] paramAuthId)
{
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}

		char authId[35];
		GetClientAuthId(i, AuthId_Steam2, authId, sizeof(authId));

		if (StrEqual(authId, paramAuthId))
		{
			return i;
		}
	}

	return -1;
}

public int GetOtherConnectedPlayersCount(int clientToIgnore)
{
	int otherConnectedPlayersCount = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (i == clientToIgnore)
		{
			continue;
		}

		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			otherConnectedPlayersCount++;
		}
	}

	return otherConnectedPlayersCount;
}

public int GetPlayerAllowedTeam(int playerClient)
{
	char authId[35];
	GetClientAuthId(playerClient, AuthId_Steam2, authId, sizeof(authId));

	for (int i = 0; i < _playerCount; i++)
	{
		if (StrEqual(authId, _playerAuthIdInfo[i]))
		{
			if (_playerTeamInfo[i] < 2)
			{
				return _playerTeamInfo[i];
			}
			
			if (_playerTeamInfo[i] == 2)
			{
				return GetTeamATeam();
			}

			return GetTeamBTeam();
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

public int GetTeamATeam()
{
	int gameNumber = _teamAGameWins + _teamBGameWins + 1;

	if (gameNumber == 1)
	{
		return _game1TeamATeam;
	}
	else if (gameNumber == 2)
	{
		return _game2TeamATeam;
	}
	else
	{
		return _game3TeamATeam;
	}
}

public int GetTeamBTeam()
{
	int teamATeam = GetTeamATeam();
	if (teamATeam == 2)
	{
		return 3;
	}

	return 2;
}

public void SetGameState(int gameState)
{
	if (gameState == _currentGameState)
	{
		return;
	}

	if (gameState == GAME_STATE_VOTING && _currentGameState != GAME_STATE_IDLE)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'Voting'. This should not happen!");
		return;
	}
	if (gameState == GAME_STATE_MATCH_READY && _currentGameState != GAME_STATE_VOTING)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'MatchReady'. This should not happen!");
		return;
	}
	if (gameState == GAME_STATE_MATCH_IN_PROGRESS && _currentGameState != GAME_STATE_MATCH_READY)
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Cannot set game state to 'MatchInProgress'. This should not happen!");
		return;
	}

	ClearCountdownTimer();
	ClearHintText();

	int previousGameState = _currentGameState;
	_currentGameState = gameState;

	PrintToServer("[Tournament Helper] Setting game state to %d...", _currentGameState);

	if (_currentGameState == GAME_STATE_IDLE)
	{
		if (previousGameState == GAME_STATE_MATCH_READY || previousGameState == GAME_STATE_MATCH_IN_PROGRESS)
		{
			PrintToChatAll("\x07f5bf03[Tournament Helper] Match has ended. Teams are now unlocked.");
		}
		else if (previousGameState == GAME_STATE_VOTING)
		{
			PrintToChatAll("\x07f5bf03[Tournament Helper] Voting has been cancelled. Teams are now unlocked.");
		}

		_currentVoteType = VOTE_TYPE_NONE;

		_conVar_insBotQuota.IntValue = _normalBotQuota;
		_conVar_mpIgnoreTimerConditions.IntValue = 1;
		_conVar_mpIgnoreWinConditions.IntValue = 1;
		_conVar_svVoteIssueChangelevelAllowed.IntValue = 1;

		EnableRespawning();
		ShowHintText("When both teams are ready, type: !startvote");
		return;
	}

	if (_currentGameState == GAME_STATE_VOTING)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Voting is in progress. Teams are now locked. Damage is prevented.");
	
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

		ShowHintText("Voting is in progress.");
		return;
	}
	
	if (_currentGameState == GAME_STATE_MATCH_READY)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Match is ready to start. Map is changing to %s.", _game1MapName);

		_conVar_insBotQuota.IntValue = 0;
		_matchId = 0;

		CreateMatchRecord();

		ShowHintText("Map is changing.");

		ChangeMap(_game1MapName);

		return;
	}

	if (_currentGameState == GAME_STATE_MATCH_IN_PROGRESS)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Match is now in progress...");

		_conVar_mpIgnoreTimerConditions.IntValue = 0;
		_conVar_mpIgnoreWinConditions.IntValue = 0;
		_conVar_svVoteIssueChangelevelAllowed.IntValue = 0;

		_teamAGameWins = 0;
		_teamBGameWins = 0;

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE th_matches SET startTimestamp = %d WHERE id = %d", GetTime(), _matchId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		DisableRespawning();

		return;
	}

	PrintToChatAll("\x07e50000[Tournament Helper] Unsupported game state '%d'. This should not happen!", _currentGameState);
}

// Respawn Functions

Handle _respawnTimerHandle = null;

public void DisableRespawning()
{
	if (_respawnTimerHandle != null)
	{
		KillTimer(_respawnTimerHandle);
		_respawnTimerHandle = null;
	}
}

public void EnableRespawning()
{
	if (_respawnTimerHandle != null)
	{
		PrintToServer("[Tournament Helper] Respawning is already enabled.");
		return;
	}

	DataPack pack = new DataPack();
	_respawnTimerHandle = CreateTimer(2.0, EnableRespawning_AfterDelay, pack, TIMER_REPEAT);
}

public Action EnableRespawning_AfterDelay(Handle timer, DataPack inputPack)
{
	// inputPack.Reset();
	// Don't close the inputPack handle since it is run on repeat.

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i))
		{
			int team = GetClientTeam(i);
			if ((team != 2 && team != 3) ||
					IsPlayerAlive(i) ||
					(!IsFakeClient(i) && !_playerIsRespawnable[i]))
			{
				continue;
			}

			PrintToChat(i, "[Tournament Helper] No match is in progress; respawning.");
			SDKCall(_forceRespawnHandle, i);
		}
	}

	return Plugin_Continue;
}

// Hint Text Functions

Handle _hintTextTimerHandle = null;

public void ClearHintText()
{
	if (_hintTextTimerHandle != null)
	{
		KillTimer(_hintTextTimerHandle);
		_hintTextTimerHandle = null;
	}
}

public void ShowHintText(const char[] hintText)
{
	if (_hintTextTimerHandle != null)
	{
		KillTimer(_hintTextTimerHandle);
		_hintTextTimerHandle = null;
	}

	PrintHintTextToAll(hintText);

	DataPack pack = new DataPack();
	pack.WriteString(hintText);
	_hintTextTimerHandle = CreateTimer(5.0, ShowHintText_AfterDelay, pack, TIMER_REPEAT);
}

public Action ShowHintText_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	char hintText[256];
	inputPack.ReadString(hintText, sizeof(hintText));
	// Don't close the inputPack handle since it is run on repeat.

	PrintHintTextToAll(hintText);
	return Plugin_Continue;
}

// Voting Functions

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
		SetGameState(GAME_STATE_IDLE);
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
		bool areAllPlayersReady = true;
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
				areAllPlayersReady = false;
			}
		}

		if (!areAllPlayersReady)
		{
			SetGameState(GAME_STATE_IDLE);
			return;
		}

		PrintToChatAll("\x07f5bf03[Tournament Helper] All players are ready.");
		StartVote(VOTE_TYPE_GAMEWINCOUNT, null);
	}
	else if (_currentVoteType == VOTE_TYPE_GAMEWINCOUNT)
	{
		int votedItemIndex = Handle_VoteResults_Helper_BothTeams(menu, num_clients, client_info, VOTE_TYPE_GAMEWINCOUNT);
		if (votedItemIndex < 0) {
			return; // Helper function handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Game wins required to win the match: %s", item);
		_teamGameWinsRequired = StringToInt(item);

		StartVote(VOTE_TYPE_ROUNDWINCOUNT, null);
	}
	else if (_currentVoteType == VOTE_TYPE_ROUNDWINCOUNT)
	{
		int votedItemIndex = Handle_VoteResults_Helper_BothTeams(menu, num_clients, client_info, VOTE_TYPE_ROUNDWINCOUNT);
		if (votedItemIndex < 0) {
			return; // Helper function handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Round wins required to win a game: %s", item);
		_teamRoundWinsRequired = StringToInt(item);

		StartVote(VOTE_TYPE_GAME1MAPSELECTION, null);
	}
	else if (_currentVoteType == VOTE_TYPE_GAME1MAPSELECTION)
	{
		int votedItemIndex = -1;
		if (_teamGameWinsRequired == 1)
		{
			votedItemIndex = Handle_VoteResults_Helper_BothTeams(menu, num_clients, client_info, VOTE_TYPE_GAME1MAPSELECTION);
		}
		else
		{
			votedItemIndex = Handle_VoteResults_Helper_SingleTeam(menu, num_clients, client_info, VOTE_TYPE_GAME1MAPSELECTION, 2);
		}
 
		if (votedItemIndex < 0) {
			return; // Helper function handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Team A has selected 1st map: %s", item);
		strcopy(_game1MapName, sizeof(_game1MapName), item);

		if (_teamGameWinsRequired == 1)
		{
			_game1TeamATeam = 2;
			SetGameState(GAME_STATE_MATCH_READY);
		}
		else
		{
			StartVote(VOTE_TYPE_GAME1TEAMSELECTION, null);
		}
	}
	else if (_currentVoteType == VOTE_TYPE_GAME1TEAMSELECTION)
	{
		int votedItemIndex = Handle_VoteResults_Helper_SingleTeam(menu, num_clients, client_info, VOTE_TYPE_GAME1TEAMSELECTION, 2); 
		if (votedItemIndex < 0) {
			return; // Helper function handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Team A has selected 1st game team: %s", item);
		_game1TeamATeam = ConvertTeamNameToInt(item);

		StartVote(VOTE_TYPE_GAME2MAPSELECTION, null);
	}
	else if (_currentVoteType == VOTE_TYPE_GAME2MAPSELECTION)
	{
		int votedItemIndex = Handle_VoteResults_Helper_SingleTeam(menu, num_clients, client_info, VOTE_TYPE_GAME2MAPSELECTION, 3);
		if (votedItemIndex < 0) {
			return; // Helper function handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Team B has selected 2nd map: %s", item);
		strcopy(_game2MapName, sizeof(_game2MapName), item);

		StartVote(VOTE_TYPE_GAME2TEAMSELECTION, null);
	}
	else if (_currentVoteType == VOTE_TYPE_GAME2TEAMSELECTION)
	{
		int votedItemIndex = Handle_VoteResults_Helper_SingleTeam(menu, num_clients, client_info, VOTE_TYPE_GAME2TEAMSELECTION, 3); 
		if (votedItemIndex < 0) {
			return; // Helper function handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Team B has selected 2nd game team: %s", item);
		int game2TeamBTeam = ConvertTeamNameToInt(item);
		if (game2TeamBTeam == 2)
		{
			_game2TeamATeam = 3;
		}
		else
		{
			_game2TeamATeam = 2;
		}

		StartVote(VOTE_TYPE_GAME3MAPSELECTION, null);
	}
	else if (_currentVoteType == VOTE_TYPE_GAME3MAPSELECTION)
	{
		int votedItemIndex = Handle_VoteResults_Helper_BothTeams(menu, num_clients, client_info, VOTE_TYPE_GAME3MAPSELECTION);
		if (votedItemIndex < 0) {
			return; // Helper function handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] 3rd map: %s", item);
		strcopy(_game3MapName, sizeof(_game3MapName), item);

		_game3TeamATeam = 2;
		SetGameState(GAME_STATE_MATCH_READY);
	}
	else
	{
		PrintToChatAll("\x07e50000[Tournament Helper] VoteType %d not supported. This should not happen!", _currentVoteType);
		SetGameState(GAME_STATE_IDLE);
	}
}

public int Handle_VoteResults_Helper_BothTeams(
	Menu menu,
	int num_clients,
  const int[][] client_info,
	int voteType)
{
	int insurgentsVotedItemIndex = GetTeamVoteItemIndex(menu, num_clients, client_info, 3);
	int securityVotedItemIndex = GetTeamVoteItemIndex(menu, num_clients, client_info, 2);
	if (insurgentsVotedItemIndex < 0 || securityVotedItemIndex < 0 || insurgentsVotedItemIndex != securityVotedItemIndex)
	{
		if (insurgentsVotedItemIndex >= 0 && securityVotedItemIndex >= 0)
		{
			PrintToChatAll("[Tournament Helper] Teams did not agree on an option.");	
		}
		else
		{
			if (insurgentsVotedItemIndex < 0)
			{
				PrintToChatAll("[Tournament Helper] Insurgents team did not have a majority vote on any option.");	
			}
			if (securityVotedItemIndex < 0)
			{
				PrintToChatAll("[Tournament Helper] Security team did not have a majority vote on any option.");	
			}
		}

		PrintToChatAll("\x07f5bf03[Tournament Helper] Revoting on this option.");

		StartVote(voteType, null);
		return -1;
	}

	return insurgentsVotedItemIndex;
}

public int Handle_VoteResults_Helper_SingleTeam(
	Menu menu,
	int num_clients,
  const int[][] client_info,
	int voteType,
	int votingTeam)
{
	int votedItemIndex = GetTeamVoteItemIndex(menu, num_clients, client_info, votingTeam);
	if (votedItemIndex < 0)
	{
		PrintToChatAll("[Tournament Helper] Voting team did not have a majority vote on any option.");	

		PrintToChatAll("\x07f5bf03[Tournament Helper] Revoting on this option.");

		StartVote(voteType, null);
		return -1;
	}

	return votedItemIndex;
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
			char playerName[MAX_NAME_LENGTH];
			GetClientName(client_info[i][VOTEINFO_CLIENT_INDEX], playerName, sizeof(playerName));
			char item[64];
			menu.GetItem(client_info[i][VOTEINFO_CLIENT_ITEM], item, sizeof(item));
			PrintToChatAll("[Tournament Helper] '%s' voted '%s'", playerName, item);

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
		if (playerVoteItemIndex < 0)
		{
			// Player didn't vote.
			continue;
		}

		teamVoteCountByItem[playerVoteItemIndex]++;
		teamVoteCountTotal++;
	}

	if (teamVoteCountTotal == 0)
	{
		return -team;
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

	int teamToVote = -1;
	if (voteType == VOTE_TYPE_READY)
	{
		StartVoteHelper_PopulateReadyMenu(menu, inputPack);
		SetGameState(GAME_STATE_VOTING);
	}
	else if (voteType == VOTE_TYPE_GAMEWINCOUNT)
	{
		StartVoteHelper_PopulateGameWinCountMenu(menu);
	}
	else if (voteType == VOTE_TYPE_ROUNDWINCOUNT)
	{
		StartVoteHelper_PopulateRoundWinCountMenu(menu);
	}
	else if (voteType == VOTE_TYPE_GAME1MAPSELECTION)
	{
		StartVoteHelper_PopulateMapMenu(menu, "1st");

		if (_teamGameWinsRequired > 1)
		{
			teamToVote = 2;
		}
	}
	else if (voteType == VOTE_TYPE_GAME1TEAMSELECTION)
	{
		StartVoteHelper_PopulateTeamSelectionMenu(menu);
		teamToVote = 2;
	}
	else if (voteType == VOTE_TYPE_GAME2MAPSELECTION)
	{
		StartVoteHelper_PopulateMapMenu(menu, "2nd");
		teamToVote = 3;
	}
	else if (voteType == VOTE_TYPE_GAME2TEAMSELECTION)
	{
		StartVoteHelper_PopulateTeamSelectionMenu(menu);
		teamToVote = 3;
	}
	else if (voteType == VOTE_TYPE_GAME3MAPSELECTION)
	{
		StartVoteHelper_PopulateMapMenu(menu, "3rd");
	}
	else
	{
		PrintToChatAll("\x07e50000[Tournament Helper] Unsupported vote type '%d'.", voteType);
		return 1;
	}
	
	_currentVoteType = voteType;

	ShowCountdownTimer(30, "Time remaining for current vote");

	int[] clients = new int[MaxClients];
	int clientCount = 0;
	for(int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			int team = GetClientTeam(i);
			if (team == teamToVote ||
					(teamToVote == -1 && (team == 2 || team == 3)))
			clients[clientCount++] = i;
		}
	}

	menu.DisplayVote(clients, clientCount, 30);

	return 0;
}

public int StartVoteHelper_PopulateGameWinCountMenu(Menu menu)
{
	menu.SetTitle("Select amount of game wins required to win the match.");
	menu.AddItem("1", "Best 1 out of 1 maps.");
	menu.AddItem("2", "Best 2 out of 3 maps.");
}

Handle _mapArray = null;
int mapSerial = -1;

public int StartVoteHelper_PopulateMapMenu(Menu menu, const char[] ordinalNumber)
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

	menu.SetTitle("Select the %s map.", ordinalNumber);
	
	int mapCount = GetArraySize(_mapArray);
	char lastMapName[PLATFORM_MAX_PATH];
	for (int i = 0; i < mapCount; i++)
	{
		char mapName[PLATFORM_MAX_PATH];
		GetArrayString(_mapArray, i, mapName, sizeof(mapName));

		char mapDisplayName[PLATFORM_MAX_PATH];
		GetMapDisplayName(mapName, mapDisplayName, sizeof(mapDisplayName));

		if (i == 0 || !StrEqual(mapName, lastMapName))
		{
			menu.AddItem(mapName, mapDisplayName);
		}

		GetArrayString(_mapArray, i, lastMapName, sizeof(lastMapName));
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

public int StartVoteHelper_PopulateRoundWinCountMenu(Menu menu)
{
	menu.SetTitle("Select amount of round wins required to win a game.");
	menu.AddItem("2", "Best 2 out of 3 rounds.");
	menu.AddItem("3", "Best 3 out of 5 rounds.");
	menu.AddItem("4", "Best 4 out of 7 rounds.");
	menu.AddItem("5", "Best 5 out of 9 rounds.");
	menu.AddItem("6", "Best 6 out of 11 rounds.");
}

public int StartVoteHelper_PopulateTeamSelectionMenu(Menu menu)
{
	menu.SetTitle("Select the team you want to play as for your selected map.");
	menu.AddItem("security", "Security");
	menu.AddItem("insurgents", "Insurgents");
}

// Countdown Timer Functions

int _countdownTimeRemaining = 0;
Handle _countdownTimeRemainingHandle = null;

public void ClearCountdownTimer()
{
	if (_countdownTimeRemainingHandle != null)
	{
		KillTimer(_countdownTimeRemainingHandle);
		_countdownTimeRemainingHandle = null;
	}

	PrintCenterTextAll("");
}

public void ShowCountdownTimer(int seconds, const char[] message)
{
	if (_countdownTimeRemainingHandle != null)
	{
		KillTimer(_countdownTimeRemainingHandle);
		_countdownTimeRemainingHandle = null;
	}

	PrintCenterTextAll("%s: %ds", message, seconds);

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

	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_state (key VARCHAR(64) PRIMARY KEY, valueInt INT(11), valueString VARCHAR(256))");
	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_playerAuthIdInfo (i INT(3) PRIMARY KEY, value VARCHAR(35) NOT NULL)");
	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_playerTeamInfo (i INT(3) PRIMARY KEY, value INT(2) NOT NULL)");

	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_matches (id INTEGER PRIMARY KEY AUTOINCREMENT, readyTimestamp INT(11) NOT NULL, startTimestamp INT(11) NULL, endTimestamp INT(11) NULL, teamAGameWins INT(3) NOT NULL, teamBGameWins INT(3) NOT NULL, matchWinningTeam VARCHAR(1) NOT NULL)");
	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_players (authId VARCHAR(35), matchId INT(8) NOT NULL, team INT(3) NOT NULL, name VARCHAR(128) NOT NULL, UNIQUE(authId, matchId))");
}

public void SqlQueryCallback_Command_MatchHistory1(Handle database, Handle handle, const char[] sError, int client)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_MatchHistory1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		ReplyToCommand(client, "[Tournament Helper] No rows found for selected query.");
		return;
	}

	ReplyToCommand(client, "ID      | ReadyTimestamp   | StartTimestamp   | EndTimestamp     | GameWins | MatchWinner");
	while (SQL_FetchRow(handle))
	{
		int id = SQL_FetchInt(handle, 0);
		int readyTimestamp = SQL_FetchInt(handle, 1);
		int startTimestamp = SQL_FetchInt(handle, 2);
		int endTimestamp = SQL_FetchInt(handle, 3);
		int teamAGameWins = SQL_FetchInt(handle, 4);
		int teamBGameWins = SQL_FetchInt(handle, 5);
		char matchWinningTeam[2];
		SQL_FetchString(handle, 6, matchWinningTeam, sizeof(matchWinningTeam));

		char readyDateTime[32]; 
		FormatTime(readyDateTime, sizeof(readyDateTime), "%F %R", readyTimestamp);
		char startDateTime[32]; 
		FormatTime(startDateTime, sizeof(startDateTime), "%F %R", startTimestamp);
		char endDateTime[32]; 
		FormatTime(endDateTime, sizeof(endDateTime), "%F %R", endTimestamp);

		ReplyToCommand(client, "%7d | %16s | %16s | %16s | %d-%d      | Team %s     ", id, readyDateTime, startDateTime, endDateTime, teamAGameWins, teamBGameWins, matchWinningTeam);
	}
}

public void CreateMatchRecord()
{
	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString),
		"INSERT INTO th_matches (readyTimestamp, teamAGameWins, teamBGameWins, matchWinningTeam) VALUES (%d, %d, %d, '%c')",
		 GetTime(), 0, 0, '-');
	SQL_TQuery(_database, SqlQueryCallback_CreateMatchRecord1, queryString);
}

public void SqlQueryCallback_CreateMatchRecord1(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_CreateMatchRecord1: '%s'", sError);
	}

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT id FROM th_matches order by id DESC LIMIT 1");
	SQL_TQuery(_database, SqlQueryCallback_CreateMatchRecord2, queryString);
}

public void SqlQueryCallback_CreateMatchRecord2(Handle database, Handle handle, const char[] sError, any data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_CreateMatchRecord2: '%s'", sError);
	}

	SQL_FetchRow(handle);
	
	_matchId = SQL_FetchInt(handle, 0);

	for (int i = 0; i < _playerCount; i++)
	{
		int client = GetClientFromAuthId(_playerAuthIdInfo[i]);

		char playerName[MAX_NAME_LENGTH];
		if (client > 0)
		{
			GetClientName(client, playerName, sizeof(playerName));
		}
		else
		{
			playerName = "Unknown";
		}

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "INSERT INTO th_players (authId, matchId, team, name) VALUES ('%s', %d, %d, '%s')", _playerAuthIdInfo[i], _matchId, _playerTeamInfo[i], playerName);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}
}

public void SaveState()
{
	PrintToServer("[Tournament Helper] Saving state...");

	char queryString1[1028];
	SQL_FormatQuery(
		_database, queryString1, sizeof(queryString1),
		"REPLACE INTO th_state (key, valueInt) VALUES ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d)",
		"conVar_insBotQuota_value", _conVar_insBotQuota.IntValue,
		"conVar_mpIgnoreTimerConditions_value", _conVar_mpIgnoreTimerConditions.IntValue,
		"conVar_mpIgnoreWinConditions_value", _conVar_mpIgnoreWinConditions.IntValue,
		"conVar_svVoteIssueChangelevelAllowed_value", _conVar_svVoteIssueChangelevelAllowed.IntValue,
		"currentGameState", _currentGameState,
		"currentVoteType", _currentVoteType,
		"game1TeamATeam", _game1TeamATeam,
		"game2TeamATeam", _game2TeamATeam,
		"game3TeamATeam", _game3TeamATeam,
		"lastMapChangeTimestamp", _lastMapChangeTimestamp,
		"matchId", _matchId,
		"playerCount", _playerCount,
		"teamAGameWins", _teamAGameWins,
		"teamBGameWins", _teamBGameWins,
		"teamGameWinsRequired", _teamGameWinsRequired,
		"teamRoundWinsRequired", _teamRoundWinsRequired);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString1);

	char queryString2[512];
	SQL_FormatQuery(
		_database, queryString2, sizeof(queryString2),
		"REPLACE INTO th_state (key, valueString) VALUES ('%s', '%s'), ('%s', '%s'), ('%s', '%s')",
		"game1MapName", _game1MapName,
		"game2MapName", _game2MapName,
		"game3MapName", _game3MapName);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);

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
	PrintToServer("[Tournament Helper] Loading state...");

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

	int currentGameState = 0;
	while (SQL_FetchRow(handle))
	{
		char key[64];
		SQL_FetchString(handle, 0, key, sizeof(key));

		int valueInt = SQL_FetchInt(handle, 1);

		char valueString[256];
		SQL_FetchString(handle, 2, valueString, sizeof(valueString));

		if (StrEqual(key, "conVar_insBotQuota_value"))
		{
			_conVar_insBotQuota.IntValue = valueInt;
		}
		else if (StrEqual(key, "conVar_mpIgnoreTimerConditions_value"))
		{
			_conVar_mpIgnoreTimerConditions.IntValue = valueInt;
		}
		else if (StrEqual(key, "conVar_mpIgnoreWinConditions_value"))
		{
			_conVar_mpIgnoreWinConditions.IntValue = valueInt;
		}
		else if (StrEqual(key, "conVar_svVoteIssueChangelevelAllowed_value"))
		{
			_conVar_svVoteIssueChangelevelAllowed.IntValue = valueInt;
		}
		else if (StrEqual(key, "currentGameState"))
		{
			currentGameState = valueInt;
		}
		else if (StrEqual(key, "currentVoteType"))
		{
			_currentVoteType = valueInt;
		}
		else if (StrEqual(key, "game1MapName"))
		{
			strcopy(_game1MapName, sizeof(_game1MapName), valueString);
		}
		else if (StrEqual(key, "game1TeamATeam"))
		{
			_game1TeamATeam = valueInt;
		}
		else if (StrEqual(key, "game2MapName"))
		{
			strcopy(_game2MapName, sizeof(_game2MapName), valueString);
		}
		else if (StrEqual(key, "game2TeamATeam"))
		{
			_game2TeamATeam = valueInt;
		}
		else if (StrEqual(key, "game3MapName"))
		{
			strcopy(_game3MapName, sizeof(_game3MapName), valueString);
		}
		else if (StrEqual(key, "game3TeamATeam"))
		{
			_game3TeamATeam = valueInt;
		}
		else if (StrEqual(key, "_lastMapChangeTimestamp"))
		{
			_lastMapChangeTimestamp = valueInt;
		}
		else if (StrEqual(key, "matchId"))
		{
			_matchId = valueInt;
		}
		else if (StrEqual(key, "playerCount"))
		{
			_playerCount = valueInt;
		}
		else if (StrEqual(key, "teamAGameWins"))
		{
			_teamAGameWins = valueInt;
		}
		else if (StrEqual(key, "teamBGameWins"))
		{
			_teamBGameWins = valueInt;
		}
		else if (StrEqual(key, "teamGameWinsRequired"))
		{
			_teamGameWinsRequired = valueInt;
		}
		else if (StrEqual(key, "teamRoundWinsRequired"))
		{
			_teamRoundWinsRequired = valueInt;
			ChangeMpMaxRounds((valueInt * 2) - 1);
			ChangeMpWinLimit(valueInt);
		}
	}

	if (currentGameState == GAME_STATE_MATCH_READY || currentGameState == GAME_STATE_MATCH_IN_PROGRESS)
	{
		SetGameState(GAME_STATE_MATCH_IN_PROGRESS);
	}
	else
	{
		SetGameState(GAME_STATE_IDLE);
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