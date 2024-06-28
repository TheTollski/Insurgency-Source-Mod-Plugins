#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

int _playerLastSpawnTimestamps[MAXPLAYERS + 1] = { -1, ... };

public Plugin myinfo =
{
	name = "Spawn Protection",
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
	CreateConVar("sm_spawnprotection_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	HookEvent("player_spawn", Event_PlayerSpawn);
}

public void OnClientPutInServer(int client) 
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage); 
} 

//
// Commands
//

//
// Hooks
//

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damageType, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
	//PrintToChatAll("OnTakeDamage. victim: %d, attacker: %d, inflictor: %d, dmg: %0.1f, damageType: %d, weapon: %d", victim, attacker, inflictor, damage, damageType, weapon);

	if (_playerLastSpawnTimestamps[victim] < 0) 
	{ 
		return Plugin_Continue; 
	}
	
	int timeSinceVictimSpawned = GetTime() - _playerLastSpawnTimestamps[victim];
	if (timeSinceVictimSpawned > 5)
	{
		return Plugin_Continue;
	}

	int localDamage = RoundToNearest(damage);
	damage = 0.0; // Prevent damage to victim.

	if (timeSinceVictimSpawned <= 2)
	{
		PrintToChat(attacker, "\x07f5bf03[Spawn Protection] Reflecting damage, that player spawned %d seconds ago.", timeSinceVictimSpawned);
		DealDamageToClient(attacker, localDamage);
	}
	else
	{
		PrintToChat(attacker, "\x07f5bf03[Spawn Protection] Preventing damage, that player spawned %d seconds ago.", timeSinceVictimSpawned);			
	}

	return Plugin_Changed;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	//PrintToChatAll("player_spawn. teamnum: %d, userid: %s", teamnum, userid);

	// int teamnum = event.GetInt("teamnum");
	int userid = event.GetInt("userid");

	int client = GetClientOfUserId(userid);

	_playerLastSpawnTimestamps[client] = GetTime();
}

//
// Helper Functions
//

public void DealDamageToClient(int client, int damage)
{
	if (!IsPlayerAlive(client))
	{
		return;
	}

	int health = GetClientHealth(client);
	if (health <= damage) 
	{ 
		ForcePlayerSuicide(client); 
	} 
	else
	{
		SetEntityHealth(client, health - damage);	
	}
}