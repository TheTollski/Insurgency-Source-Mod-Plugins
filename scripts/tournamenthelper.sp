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
int _matchId = 0;
char _playerAuthIdInfo[MAXPLAYERS + 1][35];
int _playerCount = 0;
bool _playerIsRespawnable[MAXPLAYERS + 1] = { false, ...};
int _playerTeamInfo[MAXPLAYERS + 1] = { -1, ... };
bool _pluginIsChangingMpIgnoreTimerConditions = false;
bool _pluginIsChangingMpIgnoreWinConditions = false;
bool _pluginIsChangingMpMaxRounds = false;
bool _pluginIsChangingMpWinLimit = false;
int _team1GameWins = 0; // This team joined as insurgents.
int _team2GameWins = 0; // This team joined as security.
int _team1RoundWins = 0;
int _team2RoundWins = 0;
int _teamGameWinsRequired = 0;
int _teamRoundWinsRequired = 0;

// TODO:
// Automatically change map when match is over, or print hint text.
// Improve map voting.
  // For best 2/3 each team selects a map independently and the team they will be on for that map. For 3rd map (or 1/1), teams vote on map together and teams are random?
	// Temporary: Ability to call vote during vote screen.
// Allowing late players to join/swapping players in the middle of a match
// Print winner at end of each game and game wins per team.
// Teams are forced to not change?
// Ability to pause the game.
// Bug: Security left server and then Insurgents had to repick class.
// Remove bots as players join.
// Allow all players to join teams before starting first round of a game.

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

	_conVar_mpIgnoreTimerConditions.AddChangeHook(ConVarChanged_MpIgnoreTimerConditions);
	_conVar_mpIgnoreWinConditions.AddChangeHook(ConVarChanged_MpIgnoreWinConditions);
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

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	if (_currentGameState == GAME_STATE_NONE || _currentGameState == GAME_STATE_IDLE)
	{
		return true;
	}

	int otherConnectedPlayersCount = GetOtherConnectedPlayersCount(client);
	if (otherConnectedPlayersCount == 0) 
	{
		return true;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));
	for (int i = 0; i < _playerCount; i++)
	{
		if (StrEqual(authId, _playerAuthIdInfo[i]))
		{
			return true;
		}
	}

	if (_currentGameState == GAME_STATE_VOTING)
	{
		strcopy(rejectmsg, maxlen, "Voting is in progress for a private match.");
	}
	else
	{
		strcopy(rejectmsg, maxlen, "A private match is in progress.");
	}
	
	return false;
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

	_team1RoundWins = 0; // I thought variables were wiped on map change, why do I need to do this?
	_team2RoundWins = 0;

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
	ReplyToCommand(client, "[Tournament Helper] currentGameState: %d, currentVoteType: %d, playerCount: %d, team1GameWins: %d, team2GameWins: %d, teamGameWinsRequired: %d",
		_currentGameState, _currentVoteType, _playerCount, _team1GameWins, _team2GameWins, _teamGameWinsRequired);
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

public void ConVarChanged_MpIgnoreTimerConditions(ConVar convar, char[] oldValue, char[] newValue)
{
	if (_pluginIsChangingMpIgnoreTimerConditions)
	{
		return;
	}

	PrintToConsoleAll("[Tournament Helper] Reverting a server change to mp_ignore_timer_conditions, setting to: %s", oldValue);
	ChangeMpIgnoreTimerConditions(StringToInt(oldValue));
}

public void ConVarChanged_MpIgnoreWinConditions(ConVar convar, char[] oldValue, char[] newValue)
{
	if (_pluginIsChangingMpIgnoreWinConditions)
	{
		return;
	}

	PrintToConsoleAll("[Tournament Helper] Reverting a server change to mp_ignore_win_conditions, setting to: %s", oldValue);
	ChangeMpIgnoreWinConditions(StringToInt(oldValue));
}

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

	int winningTeam = 0;
	if (winner == 3)
	{
		_team1GameWins++;
		winningTeam = 1;

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE th_matches SET team1GameWins = team1GameWins + 1 WHERE id = %d", _matchId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}
	else if (winner == 2)
	{
		_team2GameWins++;
		winningTeam = 2;

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE th_matches SET team2GameWins = team2GameWins + 1 WHERE id = %d", _matchId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}

	PrintToChatAll("\x07f5bf03[Tournament Helper] Team %d wins the game! Team 1 game wins: %d, team 2 game wins: %d, game wins required to win the match: %d.",
		winningTeam, _team1GameWins, _team2GameWins, _teamGameWinsRequired);

	int matchWinner = -1;
	if (_team1GameWins == _teamGameWinsRequired)
	{
		matchWinner = 1;
		PrintToChatAll("\x07f5bf03[Tournament Helper] Team 1 wins the match!");
	}
	else if (_team2GameWins == _teamGameWinsRequired)
	{
		matchWinner = 2;
		PrintToChatAll("\x07f5bf03[Tournament Helper] Team 2 wins the match!");
	}

	if (matchWinner > 0)
	{
		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE th_matches SET endTimestamp = %d, matchWinningTeam = %d WHERE id = %d", GetTime(), matchWinner, _matchId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		SetGameState(GAME_STATE_IDLE);
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
		CreateTimer(0.25, PlayerTeamEvent_ChangeClientTeam_AfterDelay, pack);
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
	
	int winningTeam = 0;
	if (winner == 3)
	{
		_team1RoundWins++;
		winningTeam = 1;
	}
	else if (winner == 2)
	{
		_team2RoundWins++;
		winningTeam = 2;
	}

	PrintToChatAll("\x07f5bf03[Tournament Helper] Team %d wins the round! Team 1 round wins: %d, team 2 round wins: %d, round wins required to win the game: %d.",
		winningTeam, _team1RoundWins, _team2RoundWins, _teamRoundWinsRequired);
}

public Action PlayerTeamEvent_SetIsRespawnable_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	CloseHandle(inputPack);

	_playerIsRespawnable[client] = true;

	return Plugin_Stop;
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

public void ChangeMpIgnoreTimerConditions(int newValue)
{
	PrintToServer("[Tournament Helper] Changing mp_ignore_timer_conditions to '%d'.", newValue);

	_pluginIsChangingMpIgnoreTimerConditions = true;
	_conVar_mpIgnoreTimerConditions.IntValue = newValue;
	_pluginIsChangingMpIgnoreTimerConditions = false;
}

public void ChangeMpIgnoreWinConditions(int newValue)
{
	PrintToServer("[Tournament Helper] Changing mp_ignore_win_conditions to '%d'.", newValue);

	_pluginIsChangingMpIgnoreWinConditions = true;
	_conVar_mpIgnoreWinConditions.IntValue = newValue;
	_pluginIsChangingMpIgnoreWinConditions = false;
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
		ChangeMpIgnoreTimerConditions(1);
		ChangeMpIgnoreWinConditions(1);
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
		PrintToChatAll("\x07f5bf03[Tournament Helper] Match is ready to start. Call an in-game vote to select the first map.");

		_conVar_insBotQuota.IntValue = 0;
		_matchId = 0;

		CreateMatchRecord();		

		ShowHintText("Match is ready to start. Call an in-game vote to select the first map.");
		return;
	}

	if (_currentGameState == GAME_STATE_MATCH_IN_PROGRESS)
	{
		PrintToChatAll("\x07f5bf03[Tournament Helper] Match is now in progress...");

		ChangeMpIgnoreTimerConditions(0);
		ChangeMpIgnoreWinConditions(0);
		_conVar_svVoteIssueChangelevelAllowed.IntValue = 0;

		_team1GameWins = 0;
		_team2GameWins = 0;

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
		int votedItemIndex = Handle_VoteResults_Helper(menu, num_clients, client_info, VOTE_TYPE_GAMEWINCOUNT);
		if (votedItemIndex < 0) {
			return; // Handle_VoteResults_Helper handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Game wins required to win the match: %s", item);
		_teamGameWinsRequired = StringToInt(item);

		StartVote(VOTE_TYPE_ROUNDWINCOUNT, null);
	}
	else if (_currentVoteType == VOTE_TYPE_ROUNDWINCOUNT)
	{
		int votedItemIndex = Handle_VoteResults_Helper(menu, num_clients, client_info, VOTE_TYPE_ROUNDWINCOUNT);
		if (votedItemIndex < 0) {
			return; // Handle_VoteResults_Helper handles restarting the vote on this option.
		}

		char item[64];
		menu.GetItem(votedItemIndex, item, sizeof(item));

		PrintToChatAll("\x07f5bf03[Tournament Helper] Round wins required to win a game: %s", item);
		_teamRoundWinsRequired = StringToInt(item);

		SetGameState(GAME_STATE_MATCH_READY);
	}
	else
	{
		PrintToChatAll("\x07e50000[Tournament Helper] VoteType %d not supported. This should not happen!", _currentVoteType);
		SetGameState(GAME_STATE_IDLE);
	}
}

public int Handle_VoteResults_Helper(
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

public int StartVoteHelper_PopulateGameWinCountMenu(Menu menu)
{
	menu.SetTitle("Select amount of game wins required to win the match.");
	menu.AddItem("1", "Best 1 out of 1 maps.");
	menu.AddItem("2", "Best 2 out of 3 maps.");
}

Handle _mapArray = null;
int mapSerial = -1;

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

public int StartVoteHelper_PopulateRoundWinCountMenu(Menu menu)
{
	menu.SetTitle("Select amount of round wins required to win a game.");
	menu.AddItem("2", "Best 2 out of 3 rounds.");
	menu.AddItem("3", "Best 3 out of 5 rounds.");
	menu.AddItem("4", "Best 4 out of 7 rounds.");
	menu.AddItem("5", "Best 5 out of 9 rounds.");
	menu.AddItem("6", "Best 6 out of 11 rounds.");
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

public void ShowCountdownTimer(int seconds)
{
	if (_countdownTimeRemainingHandle != null)
	{
		KillTimer(_countdownTimeRemainingHandle);
		_countdownTimeRemainingHandle = null;
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

	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_state (key VARCHAR(64) PRIMARY KEY, value INT(11) NOT NULL)");
	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_playerAuthIdInfo (i INT(3) PRIMARY KEY, value VARCHAR(35) NOT NULL)");
	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_playerTeamInfo (i INT(3) PRIMARY KEY, value INT(2) NOT NULL)");

	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS th_matches (id INTEGER PRIMARY KEY AUTOINCREMENT, readyTimestamp INT(11) NOT NULL, startTimestamp INT(11) NULL, endTimestamp INT(11) NULL, team1GameWins INT(3) NOT NULL, team2GameWins INT(3) NOT NULL, matchWinningTeam INT(3) NOT NULL)");
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
		int team1GameWins = SQL_FetchInt(handle, 4);
		int team2GameWins = SQL_FetchInt(handle, 5);
		int matchWinningTeam = SQL_FetchInt(handle, 6);

		char readyDateTime[32]; 
		FormatTime(readyDateTime, sizeof(readyDateTime), "%F %R", readyTimestamp);
		char startDateTime[32]; 
		FormatTime(startDateTime, sizeof(startDateTime), "%F %R", startTimestamp);
		char endDateTime[32]; 
		FormatTime(endDateTime, sizeof(endDateTime), "%F %R", endTimestamp);

		ReplyToCommand(client, "%7d | %16s | %16s | %16s | %d-%d      | Team %d     ", id, readyDateTime, startDateTime, endDateTime, team1GameWins, team2GameWins, matchWinningTeam);
	}
}

public void CreateMatchRecord()
{
	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString),
		"INSERT INTO th_matches (readyTimestamp, team1GameWins, team2GameWins, matchWinningTeam) VALUES (%d, %d, %d, %d)",
		 GetTime(), 0, 0, 0);
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

	char queryString[512];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"REPLACE INTO th_state (key, value) VALUES ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d), ('%s', %d)",
		"conVar_insBotQuota_value", _conVar_insBotQuota.IntValue, "conVar_mpIgnoreTimerConditions_value", _conVar_mpIgnoreTimerConditions.IntValue, "conVar_mpIgnoreWinConditions_value", _conVar_mpIgnoreWinConditions.IntValue, "conVar_svVoteIssueChangelevelAllowed_value", _conVar_svVoteIssueChangelevelAllowed.IntValue,
		"currentGameState", _currentGameState, "currentVoteType", _currentVoteType, "lastMapChangeTimestamp", _lastMapChangeTimestamp, "matchId", _matchId, "playerCount", _playerCount, "team1GameWins", _team1GameWins, "team2GameWins", _team2GameWins,
		"teamGameWinsRequired", _teamGameWinsRequired, "teamRoundWinsRequired", _teamRoundWinsRequired);
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
		int value = SQL_FetchInt(handle, 1);

		if (StrEqual(key, "conVar_insBotQuota_value"))
		{
			_conVar_insBotQuota.IntValue = value;
		}
		else if (StrEqual(key, "conVar_mpIgnoreTimerConditions_value"))
		{
			ChangeMpIgnoreTimerConditions(value);
		}
		else if (StrEqual(key, "conVar_mpIgnoreWinConditions_value"))
		{
			ChangeMpIgnoreWinConditions(value);
		}
		else if (StrEqual(key, "conVar_svVoteIssueChangelevelAllowed_value"))
		{
			_conVar_svVoteIssueChangelevelAllowed.IntValue = value;
		}
		else if (StrEqual(key, "currentGameState"))
		{
			currentGameState = value;
		}
		else if (StrEqual(key, "currentVoteType"))
		{
			_currentVoteType = value;
		}
		else if (StrEqual(key, "_lastMapChangeTimestamp"))
		{
			_lastMapChangeTimestamp = value;
		}
		else if (StrEqual(key, "matchId"))
		{
			_matchId = value;
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
		else if (StrEqual(key, "teamRoundWinsRequired"))
		{
			_teamRoundWinsRequired = value;
			ChangeMpMaxRounds((value * 2) - 1);
			ChangeMpWinLimit(value);
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