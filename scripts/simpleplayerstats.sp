#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

Database _database;
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
	
	HookEvent("player_team", Event_PlayerTeam);

	RegConsoleCmd("sm_mystats", Command_MyStats, "Prints your stats.");

	ConnectToDatabase();
}

public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	UpdateClientActiveAndConnectedTimes(client);

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

	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS sps_players (AuthId VARCHAR(35) NOT NULL, PlayerName VARCHAR(64) NOT NULL, FirstConnectionTimestamp INT(11) NOT NULL, LastConnectionTimestamp INT(11) NOT NULL, ConnectionCount INT(7) NOT NULL, ConnectedTime INT(9) NOT NULL, ActiveTime INT(9) NOT NULL, TotalKills INT(8) NOT NULL, BotKills INT(8) NOT NULL, PlayerKills INT(8) NOT NULL, TotalDeaths INT(8) NOT NULL, DeathsToBots INT(8) NOT NULL, DeathsToPlayers INT(8) NOT NULL, UNIQUE(AuthId))");
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
	int totalKills = SQL_FetchInt(handle, 7);
	int botKills = SQL_FetchInt(handle, 8);
	int playerKills = SQL_FetchInt(handle, 9);
	int totalDeaths = SQL_FetchInt(handle, 10);
	int deathsToBots = SQL_FetchInt(handle, 11);
	int deathsToPlayers = SQL_FetchInt(handle, 12);

	PrintToConsole(
		client,
		"[Simple Player Stats] Your Stats -- ConnectionCount: %d - ConnectedTime: %dh%dm - ActiveTime: %dh%dm - TotalKills: %d - BotKills: %d - PlayerKills: %d, TotalDeaths: %d, DeathsToBots: %d, DeathsToPlayers: %d",
		connectionCount, connectedTime / 3600, connectedTime % 3600 / 60, activeTime / 3600, activeTime % 3600 / 60, totalKills, botKills, playerKills, totalDeaths, deathsToBots, deathsToPlayers);
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

	if (SQL_GetRowCount(handle) == 0)
	{
		char queryString[512];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "INSERT INTO sps_players (AuthId, PlayerName, FirstConnectionTimestamp, LastConnectionTimestamp, ConnectionCount, ConnectedTime, ActiveTime, TotalKills, BotKills, PlayerKills, TotalDeaths, DeathsToBots, DeathsToPlayers) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)", authId, name, timestamp, timestamp, 1, 0, 0, 0, 0, 0, 0, 0, 0);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		PrintToChat(client, "Welcome %s, this is your first time here!", name);
		return;
	}

	SQL_FetchRow(handle);

	int connectionCount = SQL_FetchInt(handle, 4);
	int connectedTime = SQL_FetchInt(handle, 5);
	int activeTime = SQL_FetchInt(handle, 6);

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET LastConnectionTimestamp = %d, ConnectionCount = ConnectionCount + 1, PlayerName = '%s' WHERE AuthId = '%s'", timestamp, name, authId);
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
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE sps_players SET ActiveTime = ActiveTime + %d, ConnectedTime = ConnectedTime + %d WHERE AuthId = '%s'", additionalActiveTime, additionalConnectedTime, authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);
}