#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

Database _database;

public Plugin myinfo = 
{
	name = "Simple Player Stats",
	author = "Tollski",
	description = "",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

public void OnPluginStart()
{
	CreateConVar("sm_simpleplayerstats_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	ConnectToDatabase();
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
		return;

	char authId[35];
	GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "SELECT * FROM simpleplayerstats_players WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_OnClientPostAdminCheck1, queryString, GetClientUserId(client));
}

public void ConnectToDatabase()
{
	char error[256];
	_database = SQLite_UseDatabase("sourcemod-local", error, sizeof(error));
	if (_database == INVALID_HANDLE)
	{
		SetFailState("Failed to connect to the database 'sourcemod-local' with the error: '%s'", error);
		return;
	}

	SQL_TQuery(_database, SqlQueryCallback_Default, "CREATE TABLE IF NOT EXISTS simpleplayerstats_players (AuthId VARCHAR(35) NOT NULL, PlayerName VARCHAR(64) NOT NULL, FirstJoinTimestamp INT(11) NOT NULL, ConnectionCount INT(7) NOT NULL, ConnectedTime INT(9) NOT NULL, ActiveTime INT(9) NOT NULL, TotalKills INT(8) NOT NULL, BotKills INT(8) NOT NULL, PlayerKills INT(8) NOT NULL, TotalDeaths INT(8) NOT NULL, DeathsToBots INT(8) NOT NULL, DeathsToPlayers INT(8) NOT NULL, UNIQUE(AuthId))");
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

	if (SQL_GetRowCount(handle) == 0)
	{
		char authId[35];
		GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

		char name[64];
		GetClientName(client, name, sizeof(name));

		int timestamp = GetTime();

		char queryString[512];
		SQL_FormatQuery(_database, queryString, sizeof(queryString), "INSERT INTO simpleplayerstats_players (AuthId, PlayerName, FirstJoinTimestamp, ConnectionCount, ConnectedTime, ActiveTime, TotalKills, BotKills, PlayerKills, TotalDeaths, DeathsToBots, DeathsToPlayers) VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)", authId, name, timestamp, 1, 0, 0, 0, 0, 0, 0, 0, 0);
		SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

		PrintToChat(client, "Welcome %s, this is your first time here!", name);
		return;
	}

	SQL_FetchRow(handle);
	
	char authId[35];
	SQL_FetchString(handle, 0, authId, sizeof(authId));

	char name[64];
	SQL_FetchString(handle, 1, name, sizeof(name));

	int connectionCount = SQL_FetchInt(handle, 3);

	char queryString[256];
	SQL_FormatQuery(_database, queryString, sizeof(queryString), "UPDATE simpleplayerstats_players SET ConnectionCount = ConnectionCount + 1 WHERE AuthId = '%s'", authId);
	SQL_TQuery(_database, SqlQueryCallback_Default, queryString);

	PrintToChat(client, "Welcome %s, you have connected to this server %d times.", name, connectionCount + 1);
}