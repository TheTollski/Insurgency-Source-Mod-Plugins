#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.00"

StringMap _authIdDisconnectTimestampMap;
Database _database;
int _controlPointsThatPlayersAreTouching[MAXPLAYERS + 1] = { -1, ... };
bool _isChangingName[MAXPLAYERS + 1] = { false, ... };
int _lastActiveTimeSavedTimestamps[MAXPLAYERS + 1] = { 0, ... };
int _lastConnectedTimeSavedTimestamps[MAXPLAYERS + 1] = { 0, ... };
char _playerNames[MAXPLAYERS + 1][MAX_NAME_LENGTH];
int _playerRankIds[MAXPLAYERS + 1] = { -1, ... };
int _pluginStartTimestamp;
char _postDbCallOutput[101][1024];
int _postDbCallOutputCount = -1;

public Plugin myinfo =
{
	name = "Simple Player Stats",
	author = "Tollski",
	description = "",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

// TODO:
// Track monthly stats
// Use army ranks?
// Show rank in allstats
// Get ranks from config file (disable rank system if file empty)
// Track MVP stats
// Track accuracy stats
// Clan support
// Print output to chat
	// Use correct colors.

//
// Forwards
//

public void OnPluginStart()
{
	CreateConVar("sm_simpleplayerstats_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	HookEvent("controlpoint_captured", Event_ControlpointCaptured);
	HookEvent("controlpoint_endtouch", Event_ControlpointEndtouch);
	HookEvent("controlpoint_starttouch", Event_ControlpointStartTouch);
	HookEvent("flag_captured", Event_FlagCaptured);
	HookEvent("flag_pickup", Event_FlagPickup);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("object_destroyed", Event_ObjectDestroyed);
	HookEvent("player_changename", Event_PlayerChangeName, EventHookMode_Pre);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_team", Event_PlayerTeam);

	RegAdminCmd("sm_allstats", Command_AllStats, ADMFLAG_GENERIC, "Prints all player stats.");
	RegAdminCmd("sm_auditlogs", Command_AuditLogs, ADMFLAG_GENERIC, "Prints audit logs.");
	RegAdminCmd("sm_getcachedoutput", Command_GetCachedOutput, ADMFLAG_GENERIC, "Prints the post-DB call cached output from the last command.");
	RegAdminCmd("sm_resetstats", Command_ResetStats, ADMFLAG_GENERIC, "Resets the selected type of stats for all players.");

	RegConsoleCmd("sm_createclan", Command_CreateClan, "Creates a clan.");
	RegConsoleCmd("sm_deleteclan", Command_DeleteClan, "Deletes the clan that you are in.");
	RegConsoleCmd("sm_invitetoclan", Command_InviteToClan, "Sends an invitation to someone to join your clan.");
	RegConsoleCmd("sm_joinclan", Command_JoinClan, "Joins a clan.");
	RegConsoleCmd("sm_leaderboard", Command_Leaderboard, "Prints the leaderboard.");
	RegConsoleCmd("sm_leaveclan", Command_LeaveClan, "Leaves the clan that you are in.");
	RegConsoleCmd("sm_mystats", Command_MyStats, "Prints your stats.");

	ConnectToDatabase();
	ResetStartupStats();

	_authIdDisconnectTimestampMap = new StringMap();
	_pluginStartTimestamp = GetTime();
}

public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	UpdateClientActiveAndConnectedTimes(client);

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	int timestamp = GetTime();

	_authIdDisconnectTimestampMap.SetValue(authId, timestamp, true);
	_controlPointsThatPlayersAreTouching[client] = -1;
	_isChangingName[client] = false;
	_lastActiveTimeSavedTimestamps[client] = 0;
	_lastConnectedTimeSavedTimestamps[client] = 0;
	_playerNames[client] = "";
	_playerRankIds[client] = -1;
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	_lastConnectedTimeSavedTimestamps[client] = GetTime();
	GetClientName(client, _playerNames[client], MAX_NAME_LENGTH); // TODO: Remove user's clan tag in their actual name.

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	int timestamp = GetTime();
	int disconnectTimestamp;
	if (_authIdDisconnectTimestampMap.GetValue(authId, disconnectTimestamp) && timestamp - disconnectTimestamp < 300)
	{
		UpdateClientName(client);
		return;
	}

	EnsurePlayerCustomDatabaseRecordExists(client);
	EnsurePlayerRankedDatabaseRecordExists(client);
	EnsurePlayerStartupDatabaseRecordExists(client);
	EnsurePlayerTotalDatabaseRecordExists(client);

	UpdateClientName(client);
}

public void OnMapStart()
{
	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM sps_auditlogs LIMIT 1");
	SQL_TQuery(_database, SqlQueryCallback_OnMapStart1, queryString);
}

public Action Command_AllStats(int client, int args)
{
	char arg1[32];
	if (args >= 1)
	{
		GetCmdArg(1, arg1, sizeof(arg1));
	}
	else
	{
		arg1 = "Ranked";
	}

	char arg2[32];
	if (args >= 2)
	{
		GetCmdArg(2, arg2, sizeof(arg2));
	}
	else
	{
		arg2 = "Rank";
	}

	char arg3[32];
	if (args >= 3)
	{
		GetCmdArg(3, arg3, sizeof(arg3));
	}
	else
	{
		arg3 = "1";
	}

	char arg4[32];
	if (args >= 4)
	{
		GetCmdArg(4, arg4, sizeof(arg4));
	}
	else
	{
		arg4 = "false";
	}

	if (args != 4)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_allstats [Type('Custom'|'Ranked'|'Startup'|'Total')] [SortColumn('ActiveTime'|'DeathsToEnemyPlayers'|'EnemyPlayerKills'|'LastConnection'|'Rank')] [Page] [CacheOutput('true'|'false')]");
		ReplyToCommand(client, "\x05[Simple Player Stats] Using: sm_allstats %s %s %s %s", arg1, arg2, arg3, arg4);
	}

	char recordType[32];
	if (StrEqual(arg1, "Custom", false))
	{
		recordType = "Custom";
	}
	else if (StrEqual(arg1, "Ranked", false))
	{
		recordType = "Ranked";
	}
	else if (StrEqual(arg1, "Startup", false))
	{
		recordType = "Startup";
	}
	else if (StrEqual(arg1, "Total", false))
	{
		recordType = "Total";
	}
	else
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] Invalid type '%s'.", arg1);
		return Plugin_Handled;
	}

	char orderByColumn[32];
	if (StrEqual(arg2, "ActiveTime", false))
	{
		orderByColumn = "ActiveTime";
	}
	else if (StrEqual(arg2, "DeathsToEnemyPlayers", false))
	{
		orderByColumn = "DeathsToEnemyPlayers";
	}
	else if (StrEqual(arg2, "EnemyPlayerKills", false))
	{
		orderByColumn = "EnemyPlayerKills";
	}
	else if (StrEqual(arg2, "LastConnection", false))
	{
		orderByColumn = "LastConnectionTimestamp";
	}
	else if (StrEqual(arg2, "Rank", false))
	{
		orderByColumn = "RankPoints";
	}
	else
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] Invalid sort column '%s'.", arg2);
		return Plugin_Handled;
	}

	int pageSize = 50;
	int page = StringToInt(arg3);
	int offset = (page - 1) * pageSize;

	bool cacheOutput = StrEqual(arg4, "true", false);

	ReplyToCommand(client, "\x05[Simple Player Stats] %s Stats are being printed in the console.", recordType);
	if (StrEqual(recordType, "Startup"))
	{
		char dateTime[32]; 
		FormatTime(dateTime, sizeof(dateTime), "%F %R", _pluginStartTimestamp);

		ReplyToCommand(client, "\x05[Simple Player Stats] Last startup: %s", dateTime);
	}

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteCell(cacheOutput);

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"SELECT * FROM sps_players WHERE RecordType = '%s' ORDER BY %s DESC LIMIT %d OFFSET %d",
		recordType, orderByColumn, pageSize, offset);
	SQL_TQuery(_database, SqlQueryCallback_Command_AllStats1, queryString, pack);
	return Plugin_Handled;
}

public Action Command_AuditLogs(int client, int args)
{
	char arg1[32];
	if (args >= 1)
	{
		GetCmdArg(1, arg1, sizeof(arg1));
	}
	else
	{
		arg1 = "1";
	}

	if (args != 1)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_auditlogs [Page]");
		ReplyToCommand(client, "\x05[Simple Player Stats] Using: sm_auditlogs %s", arg1);
	}

	int pageSize = 50;
	int page = StringToInt(arg1);
	int offset = (page - 1) * pageSize;

	ReplyToCommand(client, "\x05[Simple Player Stats] Audit logs are being printed in the console.");

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM sps_auditlogs ORDER BY Timestamp DESC LIMIT %d OFFSET %d", pageSize, offset);
	SQL_TQuery(_database, SqlQueryCallback_Command_AuditLogs1, queryString, client);
	return Plugin_Handled;
}

public Action Command_CreateClan(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_createclan ClanTag ClanName");
		return Plugin_Handled;
	}

	char clanId[32];
	GetCmdArg(1, clanId, sizeof(clanId));

	if (strlen(clanId) < 2 || strlen(clanId) > 4)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: ClanTag must be 2-4 characters long.");
		return Plugin_Handled;
	}

	char clanName[65];
	GetCmdArg(2, clanName, sizeof(clanName));

	for (int i = 3; i <= args; i++)
	{
		char argx[65];
		GetCmdArg(i, argx, sizeof(argx));

		if (strlen(clanName) + strlen(argx) > 64)
		{
			ReplyToCommand(client, "\x05[Simple Player Stats] Usage: ClanName must be less than 64 characters long.");
			return Plugin_Handled;
		}

		Format(clanName, sizeof(clanName), "%s %s", clanName, argx);
	}

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(clanId);
	pack.WriteString(clanName);

	ReplyToCommand(client, "\x05[Simple Player Stats] Processing createclan command, output will be printed in your console.");

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"SELECT * FROM pcs_clans WHERE UPPER(ClanId) = UPPER('%s')", clanId);
	SQL_TQuery(_database, SqlQueryCallback_Command_CreateClan1, queryString, pack);
	return Plugin_Handled;
}

public Action Command_DeleteClan(int client, int args)
{
	if (args != 1)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: deleteclan ClanTag");
		return Plugin_Handled;
	}

	char clanId[32];
	GetCmdArg(1, clanId, sizeof(clanId));

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(clanId);

	ReplyToCommand(client, "\x05[Simple Player Stats] Processing deleteclan command, output will be printed in your console.");

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"SELECT * FROM pcs_player_to_clan_relationships WHERE AuthId = '%s' AND ClanId = '%s'", authId, clanId);
	SQL_TQuery(_database, SqlQueryCallback_Command_DeleteClan1, queryString, pack);
	return Plugin_Handled;
}

public Action Command_GetCachedOutput(int client, int args)
{
	char arg1[32];
	if (args >= 1)
	{
		GetCmdArg(1, arg1, sizeof(arg1));
	}
	else
	{
		arg1 = "0";
	}

	char arg2[32];
	if (args >= 2)
	{
		GetCmdArg(2, arg2, sizeof(arg2));
	}
	else
	{
		arg2 = "100";
	}

	if (args != 2)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_getcachedoutput [Start] [End]");
		ReplyToCommand(client, "\x05[Simple Player Stats] Using: sm_getcachedoutput %s %s", arg1, arg2);
	}

	int start = StringToInt(arg1);
	int end = StringToInt(arg2);

	if (start > end)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] End must be greater than or equal to start.", arg2);
		return Plugin_Handled;
	}
	if (start < 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] Start must be greater than or equal to 0.", arg2);
		return Plugin_Handled;
	}
	if (end > 100)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] End must be less than or equal to 100.", arg2);
		return Plugin_Handled;
	}

	for (int i = start; i <= _postDbCallOutputCount && i <= end; i++)
	{
		ReplyToCommand(client, _postDbCallOutput[i]);
	}

	return Plugin_Handled;
}

public Action Command_InviteToClan(int client, int args)
{
	if (args != 1)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] Usage: sm_invitetoclan ClientId");

		ReplyToCommand(client, "\x07[Simple Player Stats] Valid ClientIds:");
		ReplyToCommand(client, "\x07[Simple Player Stats] ClientId | PlayerName");
		ReplyToCommand(client, "\x07[Simple Player Stats] -------- | ----------");

		for (int i = 1; i < MaxClients + 1; i++)
		{
			if (i == client || !IsClientInGame(i) || IsFakeClient(i))
			{
				continue;
			}

			char otherClientName[MAX_NAME_LENGTH];
			GetClientName(i, otherClientName, MAX_NAME_LENGTH);
			ReplyToCommand(client, "\x07[Simple Player Stats] %8d | %s", i, otherClientName);
		}

		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));

	int inviteeClient = StringToInt(arg1);

	if (inviteeClient < 1 || inviteeClient > MaxClients || inviteeClient == client || !IsClientInGame(inviteeClient) || IsFakeClient(inviteeClient))
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: You did not select a valid ClientId.");
		return Plugin_Handled;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteCell(inviteeClient);

	ReplyToCommand(client, "\x05[Simple Player Stats] Processing invitetoclan command, output will be printed in your console.");

	char queryString[256];
	SQL_FormatQuery(
	 	_database, queryString, sizeof(queryString),
	 	"SELECT * FROM pcs_player_to_clan_relationships WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_InviteToClan1, queryString, pack);
	return Plugin_Handled;
}

public Action Command_JoinClan(int client, int args)
{
	if (args != 1)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] Usage: sm_joinclan ClanTag");
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(arg1);

	ReplyToCommand(client, "\x05[Simple Player Stats] Processing joinclan command, output will be printed in your console.");

	char queryString[256];
	SQL_FormatQuery(
	 	_database, queryString, sizeof(queryString),
	 	"SELECT * FROM pcs_clan_invitations WHERE InviteeAuthId = '%s' AND ClanId = '%s' AND %d - InvitedTimestamp < 604800", // Clan invitations are active for 7 days.
		authId, arg1, GetTime());
	SQL_TQuery(_database, SqlQueryCallback_Command_JoinClan1, queryString, pack);
	return Plugin_Handled;
}

public Action Command_Leaderboard(int client, int args)
{
	char arg1[32];
	if (args >= 1)
	{
		GetCmdArg(1, arg1, sizeof(arg1));
	}
	else
	{
		arg1 = "false";
	}

	if (args != 1)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_leaderboard [CacheOutput('true'|'false')]");
		ReplyToCommand(client, "\x05[Simple Player Stats] Using: sm_leaderboard %s", arg1);
	}

	bool isAdmin = CheckCommandAccess(client, "adminaccesscheckKick", ADMFLAG_KICK);

	bool cacheOutput = StrEqual(arg1, "true", false);
	if (cacheOutput && !isAdmin)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Only admins can set CacheOutput to true.", arg1);
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Simple Player Stats] The leaderboard is being printed in the console.");

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteCell(cacheOutput);

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"SELECT * FROM sps_players WHERE RecordType = 'Ranked' ORDER BY RankPoints DESC LIMIT 99");
	SQL_TQuery(_database, SqlQueryCallback_Command_Leaderboard1, queryString, pack);
	return Plugin_Handled;
}

public Action Command_LeaveClan(int client, int args)
{
	if (args != 0)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_leaveclan");
		return Plugin_Handled;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	ReplyToCommand(client, "\x05[Simple Player Stats] Processing leaveclan command, output will be printed in your console.");

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"SELECT * FROM pcs_player_to_clan_relationships WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_LeaveClan1, queryString, client);
	return Plugin_Handled;
}

public Action Command_MyStats(int client, int args)
{
	char arg1[32];
	if (args >= 1)
	{
		GetCmdArg(1, arg1, sizeof(arg1));
	}
	else
	{
		arg1 = "Ranked";
	}

	if (args != 1) {
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_mystats [Type('Custom'|'Ranked'|'Startup'|'Total')]");
		ReplyToCommand(client, "\x05[Simple Player Stats] Using: sm_mystats %s", arg1);
	}

	char recordType[32];
	if (StrEqual(arg1, "Custom", false))
	{
		recordType = "Custom";
	}
	else if (StrEqual(arg1, "Ranked", false))
	{
		recordType = "Ranked";
	}
	else if (StrEqual(arg1, "Startup", false))
	{
		recordType = "Startup";
	}
	else if (StrEqual(arg1, "Total", false))
	{
		recordType = "Total";
	}
	else
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] Invalid type '%s'.", arg1);
		return Plugin_Handled;
	}

	if (client == 0)
	{
		ReplyToCommand(client, "[Simple Player Stats] You can only run this command from a game client.");
		return Plugin_Handled;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	ReplyToCommand(client, "\x05[Simple Player Stats] Your %s stats are being printed in the console.", recordType);
	if (StrEqual(recordType, "Startup"))
	{
		char dateTime[32]; 
		FormatTime(dateTime, sizeof(dateTime), "%F %R", _pluginStartTimestamp);

		ReplyToCommand(client, "\x05[Simple Player Stats] Last startup: %s", dateTime);
	}

	char queryString[1024];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT p.ConnectionCount, p.ConnectedTime, p.ActiveTime, p.EnemyBotKills, p.EnemyPlayerKills, p.TeamKills, p.DeathsToEnemyBots, p.DeathsToEnemyPlayers, p.DeathsToSelf, p.DeathsToTeam, p.DeathsToOther, p.ControlPointsCaptured, p.FlagsCaptured, p.FlagsPickedUp, p.ObjectivesDestroyed, c.ConnectionCount, c.ConnectedTime, c.ActiveTime, c.EnemyBotKills, c.EnemyPlayerKills, c.TeamKills, c.DeathsToEnemyBots, c.DeathsToEnemyPlayers, c.DeathsToSelf, c.DeathsToTeam, c.DeathsToOther, c.ControlPointsCaptured, c.FlagsCaptured, c.FlagsPickedUp, c.ObjectivesDestroyed FROM sps_players AS p LEFT JOIN pcs_player_to_clan_relationships AS ptcr ON p.AuthId = ptcr.AuthId LEFT JOIN pcs_clan_stats AS c ON ptcr.ClanId = c.ClanId AND c.RecordType = '%s' WHERE p.AuthId = '%s' AND p.RecordType = '%s'", recordType, authId, recordType);
	SQL_TQuery(_database, SqlQueryCallback_Command_MyStats1, queryString, client);
	return Plugin_Handled;
}

public Action Command_ResetStats(int client, int args)
{
	char arg1[32];
	if (args >= 1)
	{
		GetCmdArg(1, arg1, sizeof(arg1));
	}
	else
	{
		arg1 = "Custom";
	}

		if (args != 1)
	{
		ReplyToCommand(client, "\x05[Simple Player Stats] Usage: sm_resetstats [Type('Custom'|'Ranked')]");
		ReplyToCommand(client, "\x05[Simple Player Stats] Using: sm_resetstats %s", arg1);
	}

	char recordType[32];
	if (StrEqual(arg1, "Custom", false))
	{
		recordType = "Custom";
	}
	else if (StrEqual(arg1, "Ranked", false))
	{
		recordType = "Ranked";
	}
	else
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] Invalid type '%s'.", arg1);
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Simple Player Stats] Resetting stats of all players for the %s Type.", recordType);

	DataPack pack = new DataPack();
	pack.WriteString(recordType);

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "DELETE FROM sps_players WHERE RecordType = '%s'", recordType);
	SQL_TQuery(_database, SqlQueryCallback_Command_ResetStats1, queryString, pack);
	return Plugin_Handled;
}

//
// Hooks
//

public void Event_ControlpointCaptured(Event event, const char[] name, bool dontBroadcast)
{
	int cp = event.GetInt("cp");
	//char cappers[256];
	//event.GetString("cappers", cappers, sizeof(cappers));
	//int oldteam = event.GetInt("oldteam");
	//int priority = event.GetInt("priority");
	int team = event.GetInt("team");
	//PrintToChatAll("\x05controlpoint_captured. cp: %d, cappers: %s, oldteam: %d, priority: %d, team: %d", cp, cappers, oldteam, priority, team);

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (_controlPointsThatPlayersAreTouching[i] == cp && team == GetClientTeam(i) && !IsFakeClient(i))
		{
			char authId[35];
			GetClientAuthId(i, AuthId_Steam2, authId, sizeof(authId));

			char queryString[256];
			SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET ControlPointsCaptured = ControlPointsCaptured + 1 WHERE AuthId = '%s'", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

			char queryString2[256];
			SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET ControlPointsCaptured = ControlPointsCaptured + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
		}
	}
}

public void Event_ControlpointEndtouch(Event event, const char[] name, bool dontBroadcast)
{
	//int area = event.GetInt("area");
	//int owner = event.GetInt("owner");
	int playerClient = event.GetInt("player");
	//int team = event.GetInt("team");
	//PrintToChatAll("\x05controlpoint_endtouch. area: %d, owner: %d, player: %d, team: %d", area, owner, playerClient, team);

	if (!IsClientConnected(playerClient) || IsFakeClient(playerClient))
	{
		return;
	}

	_controlPointsThatPlayersAreTouching[playerClient] = -1;
}

public void Event_ControlpointStartTouch(Event event, const char[] name, bool dontBroadcast)
{
	int area = event.GetInt("area");
	//int obj = event.GetInt("object");
	//int owner = event.GetInt("owner");
	int playerClient = event.GetInt("player");
	//int team = event.GetInt("team");
	//int type = event.GetInt("type");
	//PrintToChatAll("\x05controlpoint_starttouch. area: %d, object: %d, owner: %d, player: %d, team: %d, type: %d", area, obj, owner, playerClient, team, type);

	if (IsFakeClient(playerClient))
	{
		return;
	}

	_controlPointsThatPlayersAreTouching[playerClient] = area;
}

public void Event_FlagCaptured(Event event, const char[] name, bool dontBroadcast)
{
	//int priority = event.GetInt("priority");
	int userid = event.GetInt("userid");
	//PrintToChatAll("\x05flag_captured. priority: %d, userid: %d", priority, userid);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client))
	{
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET FlagsCaptured = FlagsCaptured + 1 WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	char queryString2[256];
	SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET FlagsCaptured = FlagsCaptured + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
}

public void Event_FlagPickup(Event event, const char[] name, bool dontBroadcast)
{
	//int cp = event.GetInt("cp");
	//int priority = event.GetInt("priority");
	int userid = event.GetInt("userid");
	//PrintToChatAll("\x05flag_captured. cp: %d, priority: %d, userid: %d", cp, priority, userid);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client))
	{
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET FlagsPickedUp = FlagsPickedUp + 1 WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	char queryString2[256];
	SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET FlagsPickedUp = FlagsPickedUp + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientConnected(i) && IsClientAuthorized(i) && !IsFakeClient(i))
		{
			UpdateClientRank(i);
		}
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i < MaxClients + 1; i++)
	{
		_controlPointsThatPlayersAreTouching[i] = -1;
	}
}

public void Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast)
{
	int attackerClient = event.GetInt("attacker");
	//int attackerTeam = event.GetInt("attackerteam");
	//int assister = event.GetInt("assister");
	//int cp = event.GetInt("cp");
	//int index = event.GetInt("index");
	//int team = event.GetInt("team");
	//int type = event.GetInt("type");
	//char weapon[64];
	//event.GetString("weapon", weapon, sizeof(weapon));
	//int weaponid = event.GetInt("weaponid");
	//PrintToChatAll("\x05object_destroyed. attacker: %d, attackerTeam: %d, assister: %d, cp: %d, index: %d, team: %d, type: %d, weapon: %s, weaponid: %d",
		//attackerClient, attackerTeam, assister, cp, index, team, type, weapon, weaponid);

	if (IsFakeClient(attackerClient))
	{
		return;
	}

	char authId[35];
	GetClientAuthId(attackerClient, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET ObjectivesDestroyed = ObjectivesDestroyed + 1 WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	char queryString2[256];
	SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET ObjectivesDestroyed = ObjectivesDestroyed + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
}

public Action Event_PlayerChangeName(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);

	if (_isChangingName[client])
	{
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int customkill = event.GetInt("customkill");
	if (customkill == 1)
	{
		return;
	}

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

	bool victimIsBot = IsFakeClient(victimClient);

	if ((attackerClient == 0 || attackerClient > MaxClients) && attackerTeam < 0) 
	{
		// Environment Kill
		if (victimIsBot)
		{
			return;
		}

		char authId[35];
		GetClientAuthId(victimClient, AuthId_Steam2, authId, sizeof(authId));

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET DeathsToOther = DeathsToOther + 1 WHERE AuthId = '%s'", authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		char queryString2[256];
		SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET DeathsToOther = DeathsToOther + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);

		return;
	}

	bool attackerIsBot = IsFakeClient(attackerClient);
	if (attackerIsBot && victimIsBot)
	{
		return;
	}

	if (attackerClient == victimClient) 
	{
		// Suicide
		char authId[35];
		GetClientAuthId(victimClient, AuthId_Steam2, authId, sizeof(authId));

		char queryString[256];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET DeathsToSelf = DeathsToSelf + 1 WHERE AuthId = '%s'", authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		char queryString2[256];
		SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET DeathsToSelf = DeathsToSelf + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);

		return;
	}

	if (attackerTeam == victimTeam)
	{
		// Team Kill
		if (!attackerIsBot)
		{
			char authId[35];
			GetClientAuthId(attackerClient, AuthId_Steam2, authId, sizeof(authId));

			char queryString[256];
			SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET TeamKills = TeamKills + 1 WHERE AuthId = '%s'", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

			char queryString2[256];
			SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET TeamKills = TeamKills + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
		}

		if (!victimIsBot)
		{
			char authId[35];
			GetClientAuthId(victimClient, AuthId_Steam2, authId, sizeof(authId));

			char queryString[256];
			SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET DeathsToTeam = DeathsToTeam + 1 WHERE AuthId = '%s'", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

			char queryString2[256];
			SQL_FormatQuery(_database, queryString2, sizeof(queryString2), "UPDATE pcs_clan_stats SET DeathsToTeam = DeathsToTeam + 1 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
		}

		return;
	}

	// Enemy Kill
	if (!attackerIsBot)
	{
		char authId[35];
		GetClientAuthId(attackerClient, AuthId_Steam2, authId, sizeof(authId));

		char queryString[256];
		SQL_FormatQuery(
			_database, queryString, sizeof(queryString),
			"UPDATE sps_players SET EnemyBotKills = EnemyBotKills + %d, EnemyPlayerKills = EnemyPlayerKills + %d WHERE AuthId = '%s'",
			victimIsBot ? 1 : 0, victimIsBot ? 0 : 1, authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		char queryString2[256];
		SQL_FormatQuery(
			_database, queryString2, sizeof(queryString2),
			"UPDATE pcs_clan_stats SET EnemyBotKills = EnemyBotKills + %d, EnemyPlayerKills = EnemyPlayerKills + %d WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')",
			victimIsBot ? 1 : 0, victimIsBot ? 0 : 1, authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
	}

	if (!victimIsBot)
	{
		char authId[35];
		GetClientAuthId(victimClient, AuthId_Steam2, authId, sizeof(authId));

		char queryString[256];
		SQL_FormatQuery(
			_database, queryString, sizeof(queryString),
			"UPDATE sps_players SET DeathsToEnemyBots = DeathsToEnemyBots + %d, DeathsToEnemyPlayers = DeathsToEnemyPlayers + %d WHERE AuthId = '%s'",
			attackerIsBot ? 1 : 0, attackerIsBot ? 0 : 1, authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		char queryString2[256];
		SQL_FormatQuery(
			_database, queryString2, sizeof(queryString2),
			"UPDATE pcs_clan_stats SET DeathsToEnemyBots = DeathsToEnemyBots + %d, DeathsToEnemyPlayers = DeathsToEnemyPlayers + %d WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')",
			attackerIsBot ? 1 : 0, attackerIsBot ? 0 : 1, authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
	}
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	int oldteam = event.GetInt("oldteam");
	
	//PrintToChatAll("\x05Player Team Event. userid: %d, team: %d, oldteam: %d.", userid, team, oldteam);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client))
	{
		return;
	}

	if (oldteam < 2 && team >= 2)
	{
		_lastActiveTimeSavedTimestamps[client] = GetTime();
		return;
	}

	if (oldteam >= 2 && team < 2)
	{
		UpdateClientActiveAndConnectedTimes(client);
		_lastActiveTimeSavedTimestamps[client] = 0;
		return;
	}
}

//
// 
//

public void ConnectToDatabase()
{
	char error[256];
	_database = SQLite_UseDatabase("simpleplayerstats", error, sizeof(error));
	if (_database == INVALID_HANDLE)
	{
		SetFailState("Failed to connect to the database 'simpleplayerstats' with error: '%s'", error);
		return;
	}

	SQL_TQuery(
		_database, SqlQueryCallback_Default,
		"CREATE TABLE IF NOT EXISTS sps_auditlogs (Timestamp INT(11) NOT NULL, Description VARCHAR(128) NOT NULL)");

	SQL_TQuery(
		_database, SqlQueryCallback_Default,
		"CREATE TABLE IF NOT EXISTS sps_players (AuthId VARCHAR(35) NOT NULL, RecordType VARCHAR(16) NOT NULL, PlayerName VARCHAR(64) NOT NULL, FirstConnectionTimestamp INT(11) NOT NULL, LastConnectionTimestamp INT(11) NOT NULL, ConnectionCount INT(7) NOT NULL, ConnectedTime INT(9) NOT NULL, ActiveTime INT(9) NOT NULL, EnemyBotKills INT(8) NOT NULL, EnemyPlayerKills INT(8) NOT NULL, TeamKills INT(8) NOT NULL, DeathsToEnemyBots INT(8) NOT NULL, DeathsToEnemyPlayers INT(8) NOT NULL, DeathsToSelf INT(8) NOT NULL, DeathsToTeam INT(8) NOT NULL, DeathsToOther INT(8) NOT NULL, ControlPointsCaptured INT(8) NOT NULL, FlagsCaptured INT(8) NOT NULL, FlagsPickedUp INT(8) NOT NULL, ObjectivesDestroyed INT(8) NOT NULL, RankPoints INT(9), UNIQUE(AuthId, RecordType))");

	// TODO: Separate player stats from players table.

	SQL_TQuery(
		_database, SqlQueryCallback_Default,
		"CREATE TABLE IF NOT EXISTS pcs_clans (ClanId VARCHAR(4) NOT NULL, ClanName VARCHAR(64) NOT NULL, CreationTimestamp INT(11) NOT NULL, UNIQUE(ClanId))");

	SQL_TQuery(
		_database, SqlQueryCallback_Default,
		"CREATE TABLE IF NOT EXISTS pcs_clan_stats (ClanId VARCHAR(4) NOT NULL, RecordType VARCHAR(16) NOT NULL, ConnectionCount INT(7) NOT NULL, ConnectedTime INT(9) NOT NULL, ActiveTime INT(9) NOT NULL, EnemyBotKills INT(8) NOT NULL, EnemyPlayerKills INT(8) NOT NULL, TeamKills INT(8) NOT NULL, DeathsToEnemyBots INT(8) NOT NULL, DeathsToEnemyPlayers INT(8) NOT NULL, DeathsToSelf INT(8) NOT NULL, DeathsToTeam INT(8) NOT NULL, DeathsToOther INT(8) NOT NULL, ControlPointsCaptured INT(8) NOT NULL, FlagsCaptured INT(8) NOT NULL, FlagsPickedUp INT(8) NOT NULL, ObjectivesDestroyed INT(8) NOT NULL, RankPoints INT(9), UNIQUE(ClanId, RecordType))");

	SQL_TQuery(
		_database, SqlQueryCallback_Default,
		"CREATE TABLE IF NOT EXISTS pcs_player_to_clan_relationships (AuthId VARCHAR(35) NOT NULL, ClanId VARCHAR(4) NOT NULL, RankInClan INT(2) NOT NULL, JoinTimestamp INT(11) NOT NULL, UNIQUE(AuthId))");

	SQL_TQuery(
		_database, SqlQueryCallback_Default,
		"CREATE TABLE IF NOT EXISTS pcs_clan_invitations (InviterAuthId VARCHAR(35) NOT NULL, InviteeAuthId VARCHAR(35) NOT NULL, ClanId VARCHAR(4) NOT NULL, InvitedTimestamp INT(11) NOT NULL)");
}

public void CreateAuditLog(const char[] logDescription)
{
	char queryString[512];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"INSERT INTO sps_auditlogs (Timestamp, Description) VALUES (%d, '%s')",
		GetTime(), logDescription);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
}

public int GetRank(int rankPoints, char[] rankShortName, int rankShortNameMaxLen, char[] rankLongName, int rankLongNameMaxLen)
{
	int rankId = -1;
	char longName[32];
	char shortName[5];
	if (rankPoints > 1010000)
	{
		rankId = 10;
		shortName = "ADM";
		longName = "Admiral";
	}
	else if (rankPoints > 499952)
	{
		rankId = 9;
		shortName = "VADM";
		longName = "Vice Admiral";
	}
	else if (rankPoints > 244928)
	{
		rankId = 8;
		shortName = "RADM";
		longName = "Rear Admiral Upper Half";
	}
	else if (rankPoints > 117416)
	{
		rankId = 7;
		shortName = "RDML";
		longName = "Rear Admiral Lower Half";
	}
	else if (rankPoints > 53660)
	{
		rankId = 6;
		shortName = "CAPT";
		longName = "Captain";
	}
	else if (rankPoints > 23300)
	{
		rankId = 5;
		shortName = "CDR";
		longName = "Commander";
	}
	else if (rankPoints > 9500)
	{
		rankId = 4;
		shortName = "LCDR";
		longName = "Lieutenant Commander";
	}
	else if (rankPoints > 3500)
	{
		rankId = 3;
		shortName = "LT";
		longName = "Lieutenant";
	}
	else if (rankPoints > 1000)
	{
		rankId = 2;
		shortName = "LTJG";
		longName = "Lieutenant Junior Grade";
	}
	else
	{
		rankId = 1;
		shortName = "ENS";
		longName = "Ensign";
	}

	strcopy(rankShortName, rankShortNameMaxLen, shortName);
	strcopy(rankLongName, rankLongNameMaxLen, longName);
	return rankId;
}

public void EnsureClanAnyStatsDatabaseRecordExists(const char[] clanId, const char[] recordType)
{
	DataPack pack = new DataPack();
	pack.WriteString(clanId);
	pack.WriteString(recordType);

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM pcs_clan_stats WHERE ClanId = '%s' AND RecordType = '%s'", clanId, recordType);
	SQL_TQuery(_database, SqlQueryCallback_EnsureClanAnyStatsDatabaseRecordExists1, queryString, pack);
}

public void EnsureClanCustomStatsDatabaseRecordExists(const char[] clanId)
{
	EnsureClanAnyStatsDatabaseRecordExists(clanId, "Custom");
}

public void EnsureClanRankedStatsDatabaseRecordExists(const char[] clanId)
{
	EnsureClanAnyStatsDatabaseRecordExists(clanId, "Ranked");
}

public void EnsureClanStartupStatsDatabaseRecordExists(const char[] clanId)
{
	EnsureClanAnyStatsDatabaseRecordExists(clanId, "Startup");
}

public void EnsureClanTotalStatsDatabaseRecordExists(const char[] clanId)
{
	EnsureClanAnyStatsDatabaseRecordExists(clanId, "Total");
}

public void EnsurePlayerAnyDatabaseRecordExists(int client, const char[] recordType)
{
	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(recordType);

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM sps_players WHERE AuthId = '%s' AND RecordType = '%s'", authId, recordType);
	SQL_TQuery(_database, SqlQueryCallback_EnsurePlayerDatabaseRecordExists1, queryString, pack);
}

public void EnsurePlayerCustomDatabaseRecordExists(int client)
{
	EnsurePlayerAnyDatabaseRecordExists(client, "Custom");
}

public void EnsurePlayerRankedDatabaseRecordExists(int client)
{
	EnsurePlayerAnyDatabaseRecordExists(client, "Ranked");
}

public void EnsurePlayerStartupDatabaseRecordExists(int client)
{
	EnsurePlayerAnyDatabaseRecordExists(client, "Startup");
}

public void EnsurePlayerTotalDatabaseRecordExists(int client)
{
	EnsurePlayerAnyDatabaseRecordExists(client, "Total");
}

public void ResetStartupStats()
{
	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "DELETE FROM sps_players WHERE RecordType = 'Startup'");
	SQL_TQuery(_database, SqlQueryCallback_ResetStartupStats1, queryString);
}

public void SqlQueryCallback_Command_AllStats1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	bool cacheOutput = inputPack.ReadCell();
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_AllStats1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] No rows found for selected query.");
		return;
	}

	char header[256] = "\x05PlayerName           | Rank | RnkPoints | FirstConn  | LastConn   | TotConn | PlayTime | EBKills  | EPKills  | DeathsEB | DeathsEP | Suicides | DeathsOt | Objectiv ";
	ReplyToCommand(client, header);

	if (cacheOutput)
	{
		_postDbCallOutput[0] = header;
		_postDbCallOutputCount = 1;
	}
	
	while (SQL_FetchRow(handle))
	{
		char playerName[21]; // Cut off anything past 20 characters in a player's name.
		SQL_FetchString(handle, 2, playerName, sizeof(playerName));
		int firstConnectionTimestamp = SQL_FetchInt(handle, 3);
		int lastConnectionTimestamp = SQL_FetchInt(handle, 4);
		int connectionCount = SQL_FetchInt(handle, 5);
		int activeTime = SQL_FetchInt(handle, 7);
		int enemyBotKills = SQL_FetchInt(handle, 8);
		int enemyPlayerKills = SQL_FetchInt(handle, 9);
		int deathsToEnemyBots = SQL_FetchInt(handle, 11);
		int deathsToEnemyPlayers = SQL_FetchInt(handle, 12);
		int deathsToSelf = SQL_FetchInt(handle, 13);
		int deathsToOther = SQL_FetchInt(handle, 15);
		int controlPointsCaptured = SQL_FetchInt(handle, 16);
		int flagsCaptured = SQL_FetchInt(handle, 17);
		int flagsPickedUp = SQL_FetchInt(handle, 18);
		int objectivesDestroyed = SQL_FetchInt(handle, 19);
		int rankPoints = SQL_FetchInt(handle, 20);

		char firstConnectionDate[16]; 
		FormatTime(firstConnectionDate, sizeof(firstConnectionDate), "%F", firstConnectionTimestamp);

		char lastConnectionDate[16]; 
		FormatTime(lastConnectionDate, sizeof(lastConnectionDate), "%F", lastConnectionTimestamp);

		char rankLongName[32];
		char rankShortName[5];
		int rankId = GetRank(rankPoints, rankShortName, sizeof(rankShortName), rankLongName, sizeof(rankLongName));

		char output[1024];
		Format(output, 1024, 
			"\x05%20s | %4s | %9d | %10s | %10s | %7d | %7.1fh | %8d | %8d | %8d | %8d | %8d | %8d | %8d ",
			playerName, rankShortName, rankPoints, firstConnectionDate, lastConnectionDate,
			connectionCount, ((activeTime * 100) / 3600) / float(100),
			enemyBotKills, enemyPlayerKills,
			deathsToEnemyBots, deathsToEnemyPlayers, deathsToSelf, deathsToOther,
			controlPointsCaptured + flagsPickedUp + flagsCaptured + objectivesDestroyed);

		ReplyToCommand(client, output);

		if (cacheOutput)
		{
			strcopy(_postDbCallOutput[_postDbCallOutputCount], 1024, output);
			_postDbCallOutputCount++;
		}
	}
}

public void SqlQueryCallback_Command_AuditLogs1(Handle database, Handle handle, const char[] sError, int client)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_AuditLogs1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] No rows found for selected query.");
		return;
	}

	ReplyToCommand(client, "\x05Timestamp        | Description");
	while (SQL_FetchRow(handle))
	{
		int timestamp = SQL_FetchInt(handle, 0);
		char description[128];
		SQL_FetchString(handle, 1, description, sizeof(description));

		char dateTime[32]; 
		FormatTime(dateTime, sizeof(dateTime), "%F %R", timestamp);

		ReplyToCommand(client, "\x05%16s | %s", dateTime, description);
	}
}

public void SqlQueryCallback_Command_CreateClan1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	char clanName[65];
	inputPack.ReadString(clanName, sizeof(clanName));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_CreateClan1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) > 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] A clan already exists with the tag '%s'.", clanId);
		return;
	}

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"SELECT * FROM pcs_clans WHERE UPPER(ClanName) = UPPER('%s')", clanName);
	SQL_TQuery(_database, SqlQueryCallback_Command_CreateClan2, queryString, inputPack);
}

public void SqlQueryCallback_Command_CreateClan2(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	char clanName[65];
	inputPack.ReadString(clanName, sizeof(clanName));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_CreateClan2: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) > 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] A clan already exists with the name '%s'.", clanName);
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"SELECT * FROM pcs_player_to_clan_relationships WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_CreateClan3, queryString, inputPack);
}

public void SqlQueryCallback_Command_CreateClan3(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	char clanName[65];
	inputPack.ReadString(clanName, sizeof(clanName));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_CreateClan3: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) > 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You are already in a clan. You must first leave your clan before creating a new one.");
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"INSERT INTO pcs_player_to_clan_relationships (AuthId, ClanId, RankInClan, JoinTimestamp) VALUES ('%s', '%s', %d, %d)",
		authId, clanId, 1, GetTime());
	SQL_TQuery(_database, SqlQueryCallback_Command_CreateClan4, queryString, inputPack);
}

public void SqlQueryCallback_Command_CreateClan4(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	char clanName[65];
	inputPack.ReadString(clanName, sizeof(clanName));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_CreateClan4: %d, '%s'", client, sError);
	}

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"INSERT INTO pcs_clans (ClanId, ClanName, CreationTimestamp) VALUES ('%s', '%s', %d)",
		clanId, clanName, GetTime());
	SQL_TQuery(_database, SqlQueryCallback_Command_CreateClan5, queryString, inputPack);
}

public void SqlQueryCallback_Command_CreateClan5(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	char clanName[65];
	inputPack.ReadString(clanName, sizeof(clanName));
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_CreateClan5: %d, '%s'", client, sError);
	}

	ReplyToCommand(client, "\x07[Simple Player Stats] You successfully created clan '%s'.", clanId);

	UpdateClientName(client);
	EnsureClanCustomStatsDatabaseRecordExists(clanId);
	EnsureClanRankedStatsDatabaseRecordExists(clanId);
	EnsureClanStartupStatsDatabaseRecordExists(clanId);
	EnsureClanTotalStatsDatabaseRecordExists(clanId);
}

public void SqlQueryCallback_Command_DeleteClan1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_DeleteClan1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) != 1)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You are not in the '%s' clan.", clanId);
		return;
	}

	SQL_FetchRow(handle);

	int rankInClan = SQL_FetchInt(handle, 2);

	if (rankInClan != 1)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You cannot delete a clan that you don't own.");
		return;
	}

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"DELETE FROM pcs_clans WHERE ClanId = '%s'", clanId);
	SQL_TQuery(_database, SqlQueryCallback_Command_DeleteClan2, queryString, inputPack);
}

public void SqlQueryCallback_Command_DeleteClan2(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_DeleteClan2: %d, '%s'", client, sError);
	}

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"DELETE FROM pcs_player_to_clan_relationships WHERE ClanId = '%s'", clanId);
	SQL_TQuery(_database, SqlQueryCallback_Command_DeleteClan3, queryString, inputPack);
}

public void SqlQueryCallback_Command_DeleteClan3(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_DeleteClan3: %d, '%s'", client, sError);
	}

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"DELETE FROM pcs_clan_stats WHERE ClanId = '%s'", clanId);
	SQL_TQuery(_database, SqlQueryCallback_Command_DeleteClan4, queryString, inputPack);
}

public void SqlQueryCallback_Command_DeleteClan4(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_DeleteClan4: %d, '%s'", client, sError);
	}

	ReplyToCommand(client, "\x07[Simple Player Stats] You successfully deleted clan '%s'.", clanId);

	// TODO: We should update the name of anyone in that clan who might be currently connected, but this works for now.
	UpdateClientName(client);
}

public void SqlQueryCallback_Command_InviteToClan1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	int inviteeClient = inputPack.ReadCell();
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_InviteToClan1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) != 1)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You are not in a clan.");
		return;
	}

	SQL_FetchRow(handle);

	char clanId[5];
	SQL_FetchString(handle, 1, clanId, sizeof(clanId));
	int rankInClan = SQL_FetchInt(handle, 2);

	if (rankInClan > 2)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You cannot invite other people to a clan if you are not a clan owner or officer.");
		return;
	}

	char inviterAuthId[35];
	GetClientAuthId(client, AuthId_Steam2, inviterAuthId, sizeof(inviterAuthId));
	char inviteeAuthId[35];
	GetClientAuthId(inviteeClient, AuthId_Steam2, inviteeAuthId, sizeof(inviteeAuthId));

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteCell(inviteeClient);
	pack.WriteString(clanId);

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"INSERT INTO pcs_clan_invitations (InviterAuthId, InviteeAuthId, ClanId, InvitedTimestamp) VALUES ('%s', '%s', '%s', %d)",
		inviterAuthId, inviteeAuthId, clanId, GetTime());
	SQL_TQuery(_database, SqlQueryCallback_Command_InviteToClan2, queryString, pack);
}

public void SqlQueryCallback_Command_InviteToClan2(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	int inviteeClient = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_InviteToClan2: %d, '%s'", client, sError);
	}

	char inviteeName[MAX_NAME_LENGTH];
	GetClientName(inviteeClient, inviteeName, MAX_NAME_LENGTH);

	ReplyToCommand(client, "\x07[Simple Player Stats] You successfully invited '%s' to join your clan.", inviteeName);

	PrintToChat(inviteeClient, "\x07f5bf03[Simple Player Stats] You have been invited to join the '%s' clan. To accept this invitation, enter the command: !joinclan %s", clanId, clanId);
}

public void SqlQueryCallback_Command_JoinClan1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_JoinClan1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) < 1)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You do not have an active invitation to the '%s' clan.", clanId);
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(
	 	_database, queryString, sizeof(queryString),
	 	"SELECT * FROM pcs_player_to_clan_relationships WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_JoinClan2, queryString, inputPack);
}

public void SqlQueryCallback_Command_JoinClan2(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_JoinClan2: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) > 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You are already in a clan. To join the '%s' clan you must first leave your current clan by entering: !leaveclan", clanId);
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"INSERT INTO pcs_player_to_clan_relationships (AuthId, ClanId, RankInClan, JoinTimestamp) VALUES ('%s', '%s', %d, %d)",
		authId, clanId, 3, GetTime());
	SQL_TQuery(_database, SqlQueryCallback_Command_JoinClan3, queryString, inputPack);
}

public void SqlQueryCallback_Command_JoinClan3(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char clanId[5];
	inputPack.ReadString(clanId, sizeof(clanId));
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_JoinClan3: %d, '%s'", client, sError);
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"DELETE FROM pcs_clan_invitations WHERE InviteeAuthId = '%s' AND ClanId = '%s'",
		authId, clanId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString, inputPack);

	ReplyToCommand(client, "\x07[Simple Player Stats] You have successfully joined the '%s' clan.", clanId);
	UpdateClientName(client);
}

public void SqlQueryCallback_Command_Leaderboard1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	bool cacheOutput = inputPack.ReadCell();
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_Leaderboard1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] No rows found for selected query.");
		return;
	}

	char header1[256] = "## | PlayerName                     | Rank | Rank (Full)                      | Bot Kills | Player Kills | Objectives";
	ReplyToCommand(client, header1);
	char header2[256] = "-- | ------------------------------ | ---- | -------------------------------- | --------- | ------------ | ----------";
	ReplyToCommand(client, header2);

	if (cacheOutput)
	{
		_postDbCallOutput[0] = header1;
		_postDbCallOutput[1] = header2;
		_postDbCallOutputCount = 2;
	}

	int count = 0;
	while (SQL_FetchRow(handle))
	{
		char playerName[31]; // Cut off anything past 30 characters in a player's name.
		SQL_FetchString(handle, 2, playerName, sizeof(playerName));
		int enemyBotKills = SQL_FetchInt(handle, 8);
		int enemyPlayerKills = SQL_FetchInt(handle, 9);
		int controlPointsCaptured = SQL_FetchInt(handle, 16);
		int flagsCaptured = SQL_FetchInt(handle, 17);
		int flagsPickedUp = SQL_FetchInt(handle, 18);
		int objectivesDestroyed = SQL_FetchInt(handle, 19);
		int rankPoints = SQL_FetchInt(handle, 20);

		char rankLongName[32];
		char rankShortName[5];
		int rankId = GetRank(rankPoints, rankShortName, sizeof(rankShortName), rankLongName, sizeof(rankLongName));

		char output[1024];
		Format(output, 1024, 
			"%2d | %30s | %4s | %32s | %9d | %12d | %10d ",
			count + 1, playerName, rankShortName, rankLongName,
			enemyBotKills, enemyPlayerKills,
			controlPointsCaptured + flagsPickedUp + flagsCaptured + objectivesDestroyed);

		ReplyToCommand(client, output);
		count++;

		if (cacheOutput)
		{
			strcopy(_postDbCallOutput[_postDbCallOutputCount], 1024, output);
			_postDbCallOutputCount++;
		}
	}
}

public void SqlQueryCallback_Command_LeaveClan1(Handle database, Handle handle, const char[] sError, int client)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_LeaveClan1: %d, '%s'", client, sError);
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You are not in a clan.");
		return;
	}

	SQL_FetchRow(handle);

	char authId[32];
	SQL_FetchString(handle, 0, authId, sizeof(authId));
	int rankInClan = SQL_FetchInt(handle, 2);

	if (rankInClan == 1)
	{
		ReplyToCommand(client, "\x07[Simple Player Stats] You cannot leave a clan that you own. You must delete the clan or transfer ownership of the clan to a different player.");
		return;
	}

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"DELETE FROM pcs_player_to_clan_relationships WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_LeaveClan2, queryString, client);
}

public void SqlQueryCallback_Command_LeaveClan2(Handle database, Handle handle, const char[] sError, int client)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_LeaveClan2: %d, '%s'", client, sError);
	}

	ReplyToCommand(client, "\x07[Simple Player Stats] You have successfully left your clan.");

	UpdateClientName(client);
}

public void SqlQueryCallback_Command_MyStats1(Handle database, Handle handle, const char[] sError, int client)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_MyStats1: %d, '%s'", client, sError);
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	if (SQL_GetRowCount(handle) == 0)
	{
		ThrowError("No player record was found for your AuthId '%s'", authId);
	}

	SQL_FetchRow(handle);

	int pConnectionCount = SQL_FetchInt(handle, 0);
	int pConnectedTime = SQL_FetchInt(handle, 1);
	int pActiveTime = SQL_FetchInt(handle, 2);
	int pEnemyBotKills = SQL_FetchInt(handle, 3);
	int pEnemyPlayerKills = SQL_FetchInt(handle, 4);
	int pTeamKills = SQL_FetchInt(handle, 5);
	int pDeathsToEnemyBots = SQL_FetchInt(handle, 6);
	int pDeathsToEnemyPlayers = SQL_FetchInt(handle, 7);
	int pDeathsToSelf = SQL_FetchInt(handle, 8);
	int pDeathsToTeam = SQL_FetchInt(handle, 9);
	int pDeathsToOther = SQL_FetchInt(handle, 10);
	int pControlPointsCaptured = SQL_FetchInt(handle, 11);
	int pFlagsCaptured = SQL_FetchInt(handle, 12);
	int pFlagsPickedUp = SQL_FetchInt(handle, 13);
	int pObjectivesDestroyed = SQL_FetchInt(handle, 14);

	ReplyToCommand(
		client,
		"\x05[Simple Player Stats] Your Stats -- ConnectionCount: %d - ConnectedTime: %dh%dm - ActiveTime: %dh%dm - TotalKills: %d (%d enemy bots, %d enemy players, %d team) - TotalDeaths: %d (%d enemy bots, %d enemy players, %d self, %d team, %d other) - Objectives: %d (%d control points captured, %d flags picked up, %d flags captured, %d objectives destroyed)",
		pConnectionCount, pConnectedTime / 3600, pConnectedTime % 3600 / 60, pActiveTime / 3600, pActiveTime % 3600 / 60,
		pEnemyBotKills + pEnemyPlayerKills + pTeamKills, pEnemyBotKills, pEnemyPlayerKills, pTeamKills,
		pDeathsToEnemyBots + pDeathsToEnemyPlayers + pDeathsToSelf + pDeathsToTeam + pDeathsToOther, pDeathsToEnemyBots, pDeathsToEnemyPlayers, pDeathsToSelf, pDeathsToTeam, pDeathsToOther,
		pControlPointsCaptured + pFlagsPickedUp + pFlagsCaptured + pObjectivesDestroyed, pControlPointsCaptured, pFlagsPickedUp, pFlagsCaptured, pObjectivesDestroyed);

	int firstClanStatColumnIndex = 15;
	if (!SQL_IsFieldNull(handle, firstClanStatColumnIndex))
	{
		int cConnectionCount = SQL_FetchInt(handle, firstClanStatColumnIndex);
		int cConnectedTime = SQL_FetchInt(handle, firstClanStatColumnIndex + 1);
		int cActiveTime = SQL_FetchInt(handle, firstClanStatColumnIndex + 2);
		int cEnemyBotKills = SQL_FetchInt(handle, firstClanStatColumnIndex + 3);
		int cEnemyPlayerKills = SQL_FetchInt(handle, firstClanStatColumnIndex + 4);
		int cTeamKills = SQL_FetchInt(handle, firstClanStatColumnIndex + 5);
		int cDeathsToEnemyBots = SQL_FetchInt(handle, firstClanStatColumnIndex + 6);
		int cDeathsToEnemyPlayers = SQL_FetchInt(handle, firstClanStatColumnIndex + 7);
		int cDeathsToSelf = SQL_FetchInt(handle, firstClanStatColumnIndex + 8);
		int cDeathsToTeam = SQL_FetchInt(handle, firstClanStatColumnIndex + 9);
		int cDeathsToOther = SQL_FetchInt(handle, firstClanStatColumnIndex + 10);
		int cControlPointsCaptured = SQL_FetchInt(handle, firstClanStatColumnIndex + 11);
		int cFlagsCaptured = SQL_FetchInt(handle, firstClanStatColumnIndex + 12);
		int cFlagsPickedUp = SQL_FetchInt(handle, firstClanStatColumnIndex + 13);
		int cObjectivesDestroyed = SQL_FetchInt(handle, firstClanStatColumnIndex + 14);

		ReplyToCommand(
			client,
			"\x05[Simple Player Stats] Your Clan's Stats -- ConnectionCount: %d - ConnectedTime: %dh%dm - ActiveTime: %dh%dm - TotalKills: %d (%d enemy bots, %d enemy players, %d team) - TotalDeaths: %d (%d enemy bots, %d enemy players, %d self, %d team, %d other) - Objectives: %d (%d control points captured, %d flags picked up, %d flags captured, %d objectives destroyed)",
			cConnectionCount, cConnectedTime / 3600, cConnectedTime % 3600 / 60, cActiveTime / 3600, cActiveTime % 3600 / 60,
			cEnemyBotKills + cEnemyPlayerKills + cTeamKills, cEnemyBotKills, cEnemyPlayerKills, cTeamKills,
			cDeathsToEnemyBots + cDeathsToEnemyPlayers + cDeathsToSelf + cDeathsToTeam + cDeathsToOther, cDeathsToEnemyBots, cDeathsToEnemyPlayers, cDeathsToSelf, cDeathsToTeam, cDeathsToOther,
			cControlPointsCaptured + cFlagsPickedUp + cFlagsCaptured + cObjectivesDestroyed, cControlPointsCaptured, cFlagsPickedUp, cFlagsCaptured, cObjectivesDestroyed);
	}
}

public void SqlQueryCallback_Command_ResetStats1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	char recordType[16];
	inputPack.ReadString(recordType, sizeof(recordType));
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_ResetStats1: '%s'", sError);
	}

	char auditString[64];
	Format(auditString, sizeof(auditString), "%s stats reset.", recordType);
	CreateAuditLog(auditString);

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientConnected(i) && IsClientAuthorized(i) && !IsFakeClient(i))
		{
			if (StrEqual(recordType, "Custom", false))
			{
				EnsurePlayerCustomDatabaseRecordExists(i);
			}
			else if (StrEqual(recordType, "Ranked", false))
			{
				EnsurePlayerRankedDatabaseRecordExists(i);
			}
		}
	}
}

public void SqlQueryCallback_Default(Handle database, Handle handle, const char[] sError, int data)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Default: %d, '%s'", data, sError);
	}
}

public void SqlQueryCallback_EnsureClanAnyStatsDatabaseRecordExists1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	char clanId[16];
	inputPack.ReadString(clanId, sizeof(clanId));
	char recordType[16];
	inputPack.ReadString(recordType, sizeof(recordType));
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_EnsureClanAnyStatsDatabaseRecordExists1: '%s', '%s', '%s'", clanId, recordType, sError);
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		char queryString[512];
		SQL_FormatQuery(
			_database, queryString, sizeof(queryString),
			"INSERT INTO pcs_clan_stats (ClanId, RecordType, ConnectionCount, ConnectedTime, ActiveTime, EnemyBotKills, EnemyPlayerKills, TeamKills, DeathsToEnemyBots, DeathsToEnemyPlayers, DeathsToSelf, DeathsToTeam, DeathsToOther, ControlPointsCaptured, FlagsCaptured, FlagsPickedUp, ObjectivesDestroyed) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)",
			clanId, recordType, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		return;
	}

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"UPDATE pcs_clan_stats SET ConnectionCount = ConnectionCount + 1 WHERE ClanId = '%s' AND RecordType = '%s'",
		clanId, recordType);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
}

public void SqlQueryCallback_EnsurePlayerDatabaseRecordExists1(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char recordType[16];
	inputPack.ReadString(recordType, sizeof(recordType));
	//CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_EnsurePlayerDatabaseRecordExists1: %d, '%s', '%s'", client, recordType, sError);
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	int timestamp = GetTime();

	if (SQL_GetRowCount(handle) == 0)
	{
		char queryString[512];
		SQL_FormatQuery(
			_database, queryString, sizeof(queryString),
			"INSERT INTO sps_players (AuthId, RecordType, PlayerName, FirstConnectionTimestamp, LastConnectionTimestamp, ConnectionCount, ConnectedTime, ActiveTime, EnemyBotKills, EnemyPlayerKills, TeamKills, DeathsToEnemyBots, DeathsToEnemyPlayers, DeathsToSelf, DeathsToTeam, DeathsToOther, ControlPointsCaptured, FlagsCaptured, FlagsPickedUp, ObjectivesDestroyed) VALUES ('%s', '%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)",
			authId, recordType, _playerNames[client], timestamp, timestamp, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		if (StrEqual(recordType, "Total"))
		{
			PrintToChat(client, "\x05Welcome %s, this is your first time here!", _playerNames[client]);
		}
	}
	else {
		SQL_FetchRow(handle);

		int connectionCount = SQL_FetchInt(handle, 5);
		int connectedTime = SQL_FetchInt(handle, 6);
		int activeTime = SQL_FetchInt(handle, 7);

		char queryString[256];
		SQL_FormatQuery(
			_database, queryString, sizeof(queryString),
			"UPDATE sps_players SET LastConnectionTimestamp = %d, ConnectionCount = ConnectionCount + 1, PlayerName = '%s' WHERE AuthId = '%s' AND RecordType = '%s'",
			timestamp, _playerNames[client], authId, recordType);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		if (StrEqual(recordType, "Total"))
		{
			PrintToChat(client, "\x05Welcome %s, you have played on this server %d times for %.2f hours (%.2f hours connected).", _playerNames[client], connectionCount + 1, activeTime / 3600.0, connectedTime / 3600.0);
		}
	}

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM pcs_player_to_clan_relationships WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_EnsurePlayerDatabaseRecordExists2, queryString, inputPack);
}

public void SqlQueryCallback_EnsurePlayerDatabaseRecordExists2(Handle database, Handle handle, const char[] sError, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	char recordType[16];
	inputPack.ReadString(recordType, sizeof(recordType));
	CloseHandle(inputPack);

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_EnsurePlayerDatabaseRecordExists2: %d, '%s', '%s'", client, recordType, sError);
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		return;
	}

	SQL_FetchRow(handle);

	char clanId[5];
	SQL_FetchString(handle, 1, clanId, sizeof(clanId));

	EnsureClanAnyStatsDatabaseRecordExists(clanId, recordType);
}

public void SqlQueryCallback_OnMapStart1(Handle database, Handle handle, const char[] sError, any nothing)
{
	// Since callbacks don't seem to work in methods called by OnPluginStart I have to do this in OnMapStart.

	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_OnMapStart1: '%s'", sError);
	}

	if (SQL_GetRowCount(handle) > 0)
	{
		return;
	}

	CreateAuditLog("Total stats reset.");
	CreateAuditLog("Custom stats reset.");
}

public void SqlQueryCallback_ResetStartupStats1(Handle database, Handle handle, const char[] sError, any nothing)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_ResetStartupStats1: '%s'", sError);
	}

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientConnected(i) && IsClientAuthorized(i) && !IsFakeClient(i))
		{
			EnsurePlayerStartupDatabaseRecordExists(i);
		}
	}
}

public void SqlQueryCallback_Command_UpdateClientName1(Handle database, Handle handle, const char[] sError, int client)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_UpdateClientName1: %d, '%s'", client, sError);
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	if (SQL_GetRowCount(handle) == 0)
	{
		ThrowError("No player record was found for AuthId '%s'", authId);
	}

	SQL_FetchRow(handle);

	int rankPoints = SQL_FetchInt(handle, 0);
	char clanId[5];
	SQL_FetchString(handle, 1, clanId, sizeof(clanId));

	char rankLongName[32];
	char rankShortName[5];
	GetRank(rankPoints, rankShortName, sizeof(rankShortName), rankLongName, sizeof(rankLongName));

	char clanTagString[7];
	if (strlen(clanId) > 0)
	{
		Format(clanTagString, sizeof(clanTagString), "[%s]", clanId);
	}

	char strNickname[64];
	Format(strNickname, sizeof(strNickname), "{%s}%s %s", rankShortName, clanTagString, _playerNames[client]);

	_isChangingName[client] = true;
	SetClientName(client, strNickname);
	_isChangingName[client] = false;
}

public void SqlQueryCallback_Command_UpdateClientRank1(Handle database, Handle handle, const char[] sError, int client)
{
	if (!handle)
	{
		ThrowError("SQL query error in SqlQueryCallback_Command_UpdateClientRank1: %d, '%s'", client, sError);
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	if (SQL_GetRowCount(handle) == 0)
	{
		ThrowError("No player record was found for AuthId '%s'", authId);
	}

	SQL_FetchRow(handle);

	int connectedTime = SQL_FetchInt(handle, 6);
	int activeTime = SQL_FetchInt(handle, 7);
	int enemyBotKills = SQL_FetchInt(handle, 8);
	int enemyPlayerKills = SQL_FetchInt(handle, 9);
	int controlPointsCaptured = SQL_FetchInt(handle, 16);
	int flagsCaptured = SQL_FetchInt(handle, 17);
	int flagsPickedUp = SQL_FetchInt(handle, 18);
	// int objectivesDestroyed = SQL_FetchInt(handle, 19);

	int points = connectedTime / 60 // 1 point per minute connected
		+ activeTime / 6 // 10 points per minute actively played
		+ enemyBotKills * 10 // 10 points per bot kill
		+ enemyPlayerKills * 100 // 100 points per player kill
		+ controlPointsCaptured * 100 // 100 points per control point captured
		+ flagsCaptured * 300 // 300 points per flag captured
		+ flagsPickedUp * 100; // 100 points per flag picked up

	// TODO: This should be the first level call, but the RETURNING clause doesn't seem to be working.
	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"UPDATE sps_players SET RankPoints = ConnectedTime / 60 + ActiveTime / 6 + EnemyBotKills * 10 + EnemyPlayerKills * 100 + ControlPointsCaptured * 100 + FlagsCaptured * 300 + FlagsPickedUp * 100 WHERE AuthId = '%s'",
		authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	char queryString2[256];
	SQL_FormatQuery(
		_database, queryString2, sizeof(queryString2),
		"UPDATE pcs_clan_stats SET RankPoints = ConnectedTime / 60 + ActiveTime / 6 + EnemyBotKills * 10 + EnemyPlayerKills * 100 + ControlPointsCaptured * 100 + FlagsCaptured * 300 + FlagsPickedUp * 100 WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')",
		authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);

	char rankLongName[32];
	char rankShortName[5];
	int rankId = GetRank(points, rankShortName, sizeof(rankShortName), rankLongName, sizeof(rankLongName));

	if (_playerRankIds[client] == rankId)
	{
		return;
	}

	if (_playerRankIds[client] > 0)
	{
		PrintToChatAll("\x07f5bf03%s has been promoted to %s {%s}!", _playerNames[client], rankLongName, rankShortName);
	}

	_playerRankIds[client] = rankId;

	UpdateClientName(client);
}

public void UpdateClientActiveAndConnectedTimes(int client)
{
	int timestamp = GetTime();

	int additionalActiveTime = 0;
	if (_lastActiveTimeSavedTimestamps[client] > 0)
	{
		additionalActiveTime = timestamp - _lastActiveTimeSavedTimestamps[client];
		_lastActiveTimeSavedTimestamps[client] = timestamp;
	}

	int additionalConnectedTime = 0;
	if (_lastConnectedTimeSavedTimestamps[client] > 0)
	{
		additionalConnectedTime = timestamp - _lastConnectedTimeSavedTimestamps[client];
		_lastConnectedTimeSavedTimestamps[client] = timestamp;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(
		_database, queryString, sizeof(queryString),
		"UPDATE sps_players SET ActiveTime = ActiveTime + %d, ConnectedTime = ConnectedTime + %d WHERE AuthId = '%s'",
		additionalActiveTime, additionalConnectedTime, authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	char queryString2[256];
	SQL_FormatQuery(
		_database, queryString2, sizeof(queryString2),
		"UPDATE pcs_clan_stats SET ActiveTime = ActiveTime + %d, ConnectedTime = ConnectedTime + %d WHERE ClanId = (SELECT ClanId FROM pcs_player_to_clan_relationships WHERE AuthId = '%s')",
		additionalActiveTime, additionalConnectedTime, authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString2);
}

public void UpdateClientName(int client)
{
	if (strlen(_playerNames[client]) == 0)
	{
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT p.RankPoints, ptcr.ClanId FROM sps_players p LEFT JOIN pcs_player_to_clan_relationships ptcr ON p.AuthId = ptcr.AuthId WHERE p.AuthId = '%s' AND p.RecordType = 'Ranked'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_UpdateClientName1, queryString, client);
}

public void UpdateClientRank(int client)
{
	if (strlen(_playerNames[client]) == 0)
	{
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM sps_players WHERE AuthId = '%s' AND RecordType = 'Ranked'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_UpdateClientRank1, queryString, client);
}