#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

StringMap _authIdDisconnectTimestampMap;
Database _database;
int _controlPointsThatPlayersAreTouching[MAXPLAYERS + 1] = { -1, ... };
int _lastActiveTimeSavedTimestamps[MAXPLAYERS + 1] = { 0, ... };
int _lastConnectedTimeSavedTimestamps[MAXPLAYERS + 1] = { 0, ... };

public Plugin myinfo =
{
	name = "Simple Player Stats",
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
	CreateConVar("sm_simpleplayerstats_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	HookEvent("controlpoint_captured", Event_ControlpointCaptured);
	HookEvent("controlpoint_endtouch", Event_ControlpointEndtouch);
	HookEvent("controlpoint_starttouch", Event_ControlpointStartTouch);
	HookEvent("flag_captured", Event_FlagCaptured);
	HookEvent("flag_pickup", Event_FlagPickup);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_team", Event_PlayerTeam);

	RegConsoleCmd("sm_mystats", Command_MyStats, "Prints your stats.");

	ConnectToDatabase();

	_authIdDisconnectTimestampMap = new StringMap();
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
	_lastActiveTimeSavedTimestamps[client] = 0;
	_lastConnectedTimeSavedTimestamps[client] = 0;
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}
	
	_lastConnectedTimeSavedTimestamps[client] = GetTime();

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM sps_players WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_OnClientPostAdminCheck1, queryString, GetClientUserId(client));
}

public Action Command_MyStats(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[Simple Player Stats] Usage: sm_mystats");
		return Plugin_Handled;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	ReplyToCommand(client, "[Simple Player Stats] Your stats are being printed in the console.");

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM sps_players WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Command_MyStats1, queryString, GetClientUserId(client));
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
	//PrintToChatAll("controlpoint_captured. cp: %d, cappers: %s, oldteam: %d, priority: %d, team: %d", cp, cappers, oldteam, priority, team);

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (_controlPointsThatPlayersAreTouching[i] == cp && team == GetClientTeam(i) && !IsFakeClient(i))
		{
			char playerName[64];
			GetClientName(i, playerName, sizeof(playerName));
			PrintToConsoleAll("Debug: %s helped capture a control point.", playerName);

			char authId[35];
			GetClientAuthId(i, AuthId_Steam2, authId, sizeof(authId));

			char queryString[256];
			SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET ControlPointsCaptured = ControlPointsCaptured + 1 WHERE AuthId = '%s'", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
		}
	}
}

public void Event_ControlpointEndtouch(Event event, const char[] name, bool dontBroadcast)
{
	//int area = event.GetInt("area");
	//int owner = event.GetInt("owner");
	int playerClient = event.GetInt("player");
	//int team = event.GetInt("team");
	//PrintToChatAll("controlpoint_endtouch. area: %d, owner: %d, player: %d, team: %d", area, owner, playerClient, team);

	if (IsFakeClient(playerClient))
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
	//PrintToChatAll("controlpoint_starttouch. area: %d, object: %d, owner: %d, player: %d, team: %d, type: %d", area, obj, owner, playerClient, team, type);

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
	//PrintToChatAll("flag_captured. priority: %d, userid: %d", priority, userid);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client))
	{
		return;
	}

	char playerName[64];
	GetClientName(client, playerName, sizeof(playerName));
	PrintToConsoleAll("Debug: %s captured the flag.", playerName);

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET FlagsCaptured = FlagsCaptured + 1 WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
}

public void Event_FlagPickup(Event event, const char[] name, bool dontBroadcast)
{
	//int cp = event.GetInt("cp");
	//int priority = event.GetInt("priority");
	int userid = event.GetInt("userid");
	//PrintToChatAll("flag_captured. cp: %d, priority: %d, userid: %d", cp, priority, userid);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client))
	{
		return;
	}

	char playerName[64];
	GetClientName(client, playerName, sizeof(playerName));
	PrintToConsoleAll("Debug: %s picked up the flag.", playerName);

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET FlagsPickedUp = FlagsPickedUp + 1 WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i < MaxClients + 1; i++)
	{
		_controlPointsThatPlayersAreTouching[i] = -1;
	}
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
	// PrintToChatAll("player_death. attackerUserid: %d, victimUserid: %d, attackerTeam: %d, victimTeam: %d, assister: %d, damagebits: %d, deathflags: %d, lives: %d, priority: %d, weapon: %s, weaponid: %d, x: %d, y: %d, z: %d",
	// 	attackerClient, victimUserid, attackerTeam, victimTeam, assister, damagebits, deathflags, lives, priority, weapon, weaponid, x, y ,z);

	bool victimIsBot = IsFakeClient(victimClient);

	if (attackerUserid == 0 && attackerTeam < 0) 
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
		}

		if (!victimIsBot)
		{
			char authId[35];
			GetClientAuthId(victimClient, AuthId_Steam2, authId, sizeof(authId));

			char queryString[256];
			SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET DeathsToTeam = DeathsToTeam + 1 WHERE AuthId = '%s'", authId);
			SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
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
			_database,
			queryString,
			sizeof(queryString),
			"UPDATE sps_players SET EnemyBotKills = EnemyBotKills + %d, EnemyPlayerKills = EnemyPlayerKills + %d WHERE AuthId = '%s'",
			victimIsBot ? 1 : 0, victimIsBot ? 0 : 1, authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}

	if (!victimIsBot)
	{
		char authId[35];
		GetClientAuthId(victimClient, AuthId_Steam2, authId, sizeof(authId));

		char queryString[256];
		SQL_FormatQuery(
			_database,
			queryString,
			sizeof(queryString),
			"UPDATE sps_players SET DeathsToEnemyBots = DeathsToEnemyBots + %d, DeathsToEnemyPlayers = DeathsToEnemyPlayers + %d WHERE AuthId = '%s'",
			attackerIsBot ? 1 : 0, attackerIsBot ? 0 : 1, authId);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
	}
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	int oldteam = event.GetInt("oldteam");
	
	//PrintToChatAll("Player Team Event. userid: %d, team: %d, oldteam: %d.", userid, team, oldteam);

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
		_database,
		SqlQueryCallback_Default,
		"CREATE TABLE IF NOT EXISTS sps_players (AuthId VARCHAR(35) NOT NULL, PlayerName VARCHAR(64) NOT NULL, FirstConnectionTimestamp INT(11) NOT NULL, LastConnectionTimestamp INT(11) NOT NULL, ConnectionCount INT(7) NOT NULL, ConnectedTime INT(9) NOT NULL, ActiveTime INT(9) NOT NULL, EnemyBotKills INT(8) NOT NULL, EnemyPlayerKills INT(8) NOT NULL, TeamKills INT(8) NOT NULL, DeathsToEnemyBots INT(8) NOT NULL, DeathsToEnemyPlayers INT(8) NOT NULL, DeathsToSelf INT(8) NOT NULL, DeathsToTeam INT(8) NOT NULL, DeathsToOther INT(8) NOT NULL, ControlPointsCaptured INT(8), FlagsCaptured INT(8), FlagsPickedUp INT(8), UNIQUE(AuthId))");
}

public void SqlQueryCallback_Command_MyStats1(Handle database, Handle handle, const char[] sError, int data)
{
	if (!handle)
	{
		ThrowError("SQL query error %d: '%s'", data, sError);
	}

	int client = GetClientOfUserId(data);
	if (client == 0)
	{
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	if (SQL_GetRowCount(handle) == 0)
	{
		ThrowError("No player record was found for your AuthId '%s'", authId);
	}

	SQL_FetchRow(handle);

	int connectionCount = SQL_FetchInt(handle, 4);
	int connectedTime = SQL_FetchInt(handle, 5);
	int activeTime = SQL_FetchInt(handle, 6);
	int enemyBotKills = SQL_FetchInt(handle, 7);
	int enemyPlayerKills = SQL_FetchInt(handle, 8);
	int teamKills = SQL_FetchInt(handle, 9);
	int deathsToEnemyBots = SQL_FetchInt(handle, 10);
	int deathsToEnemyPlayers = SQL_FetchInt(handle, 11);
	int deathsToSelf = SQL_FetchInt(handle, 12);
	int deathsToTeam = SQL_FetchInt(handle, 13);
	int deathsToOther = SQL_FetchInt(handle, 14);
	int controlPointsCaptured = SQL_FetchInt(handle, 15);
	int flagsCaptured = SQL_FetchInt(handle, 16);
	int flagsPickedUp = SQL_FetchInt(handle, 17);

	PrintToConsole(
		client,
		"[Simple Player Stats] Your Stats -- ConnectionCount: %d - ConnectedTime: %dh%dm - ActiveTime: %dh%dm - TotalKills: %d (%d enemy bots, %d enemy players, %d team) - TotalDeaths: %d (%d enemy bots, %d enemy players, %d self, %d team, %d other) - Objectives: %d (%d control points captured, %d flags picked up, %d flags captured)",
		connectionCount, connectedTime / 3600, connectedTime % 3600 / 60, activeTime / 3600, activeTime % 3600 / 60,
		enemyBotKills + enemyPlayerKills + teamKills, enemyBotKills, enemyPlayerKills, teamKills,
		deathsToEnemyBots + deathsToEnemyPlayers + deathsToSelf + deathsToTeam + deathsToOther, deathsToEnemyBots, deathsToEnemyPlayers, deathsToSelf, deathsToTeam, deathsToOther,
		controlPointsCaptured + flagsPickedUp + flagsCaptured, controlPointsCaptured, flagsPickedUp, flagsCaptured);
}

public void SqlQueryCallback_Default(Handle database, Handle handle, const char[] sError, int data)
{
	if (!handle)
	{
		ThrowError("SQL query error %d: '%s'", data, sError);
	}
}

public void SqlQueryCallback_OnClientPostAdminCheck1(Handle database, Handle handle, const char[] sError, int data)
{
	if (!handle)
	{
		ThrowError("SQL query error %d: '%s'", data, sError);
	}

	int client = GetClientOfUserId(data);
	if (client == 0)
	{
		return;
	}

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char name[64];
	GetClientName(client, name, sizeof(name));

	int timestamp = GetTime();

	int disconnectTimestamp;
	if (_authIdDisconnectTimestampMap.GetValue(authId, disconnectTimestamp) && timestamp - disconnectTimestamp < 300)
	{
		return;
	}

	if (SQL_GetRowCount(handle) == 0)
	{
		char queryString[512];
		SQL_FormatQuery(
			_database,
			queryString,
			sizeof(queryString),
			"INSERT INTO sps_players (AuthId, PlayerName, FirstConnectionTimestamp, LastConnectionTimestamp, ConnectionCount, ConnectedTime, ActiveTime, EnemyBotKills, EnemyPlayerKills, TeamKills, DeathsToEnemyBots, DeathsToEnemyPlayers, DeathsToSelf, DeathsToTeam, DeathsToOther, ControlPointsCaptured, FlagsCaptured, FlagsPickedUp) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)",
			authId, name, timestamp, timestamp, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		PrintToChat(client, "Welcome %s, this is your first time here!", name);
		return;
	}

	SQL_FetchRow(handle);

	int connectionCount = SQL_FetchInt(handle, 4);
	int connectedTime = SQL_FetchInt(handle, 5);
	int activeTime = SQL_FetchInt(handle, 6);

	char queryString[256];
	SQL_FormatQuery(
		_database,
		queryString,
		sizeof(queryString),
		"UPDATE sps_players SET LastConnectionTimestamp = %d, ConnectionCount = ConnectionCount + 1, PlayerName = '%s' WHERE AuthId = '%s'",
		timestamp, name, authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	PrintToChat(client, "Welcome %s, you have played on this server %d times for %dh%dm (%dh%dm active).", name, connectionCount + 1, connectedTime / 3600, connectedTime % 3600 / 60, activeTime / 3600, activeTime % 3600 / 60);
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
		_database,
		queryString,
		sizeof(queryString),
		"UPDATE sps_players SET ActiveTime = ActiveTime + %d, ConnectedTime = ConnectedTime + %d WHERE AuthId = '%s'",
		additionalActiveTime, additionalConnectedTime, authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
}