#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.01"

int _playerLastSpawnTimestamps[MAXPLAYERS + 1] = { -1, ... };
int _playerLastProtectedSpawnTimestamps[MAXPLAYERS + 1] = { -1, ... };
int _playerLastWeaponFireTimestamps[MAXPLAYERS + 1] = { -1, ... };
int _teamLastProtectedSpawnEventTimestamps[4] = { -1, ... };

public Plugin myinfo =
{
	name = "Spawn Protection",
	author = "Tollski",
	description = "",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

// TODO
// Disable on distance moved.

//
// Forwards
//

public void OnPluginStart()
{
	CreateConVar("sm_spawnprotection_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	HookEvent("controlpoint_captured", Event_ControlpointCaptured);
	HookEvent("flag_drop", Event_FlagDrop);
	HookEvent("flag_pickup", Event_FlagPickup);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("weapon_fire", Event_WeaponFire);
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
	// PrintToChatAll("OnTakeDamage. victim: %d, attacker: %d, inflictor: %d, dmg: %0.1f, damageType: %d, weapon: %d", victim, attacker, inflictor, damage, damageType, weapon);

	if (_playerLastProtectedSpawnTimestamps[victim] < 0) 
	{ 
		return Plugin_Continue; 
	}
	
	int timeSinceVictimSpawned = GetTime() - _playerLastProtectedSpawnTimestamps[victim];
	if (timeSinceVictimSpawned > 3)
	{
		return Plugin_Continue;
	}

	if (_playerLastProtectedSpawnTimestamps[victim] <= _playerLastWeaponFireTimestamps[victim])
	{
		return Plugin_Continue;
	}

	int localDamage = RoundToNearest(damage);
	damage = 0.0; // Prevent damage to victim.

	if (timeSinceVictimSpawned <= 1)
	{
		PrintToChat(attacker, "\x07f5bf03[Spawn Protection] Reflecting damage, that player spawned %d seconds ago.", timeSinceVictimSpawned);

		char attackerPanelMessage[128];
		Format(attackerPanelMessage, sizeof(attackerPanelMessage), "[Spawn Protection] You were penalized %d HP for hurting %N.", localDamage, victim);
		ShowPanelMessage(attacker, attackerPanelMessage);
		
		char victimPanelMessage[128];
		Format(victimPanelMessage, sizeof(victimPanelMessage), "[Spawn Protection] %N was penalized %d HP for hurting you.", attacker, localDamage);
		ShowPanelMessage(victim, victimPanelMessage);
		
		DealDamageToClient(attacker, localDamage);
	}
	else
	{
		PrintToChat(attacker, "\x07f5bf03[Spawn Protection] Preventing damage, that player spawned %d seconds ago.", timeSinceVictimSpawned);

		char attackerPanelMessage[128];
		Format(attackerPanelMessage, sizeof(attackerPanelMessage), "[Spawn Protection] %d of your damage was prevented to %N.", localDamage, victim);
		ShowPanelMessage(attacker, attackerPanelMessage);

		char victimPanelMessage[128];
		Format(victimPanelMessage, sizeof(victimPanelMessage), "[Spawn Protection] %d damage was prevented to you.", localDamage);
		ShowPanelMessage(victim, victimPanelMessage);
	}

	return Plugin_Changed;
}

public void Event_ControlpointCaptured(Event event, const char[] name, bool dontBroadcast)
{
	// int cp = event.GetInt("cp");
	// char cappers[256];
	// event.GetString("cappers", cappers, sizeof(cappers));
	// int oldteam = event.GetInt("oldteam");
	// int priority = event.GetInt("priority");
	int team = event.GetInt("team");
	// PrintToChatAll("controlpoint_captured. cp: %d, cappers: %s, oldteam: %d, priority: %d, team: %d", cp, cappers, oldteam, priority, team);

	ProtectTeamSpawns(team);
}

public void Event_FlagDrop(Event event, const char[] name, bool dontBroadcast)
{
	//int priority = event.GetInt("priority");
	int userid = event.GetInt("userid");
	//PrintToChatAll("flag_drop. priority: %d, userid: %d", priority, userid);

	int client = GetClientOfUserId(userid);
	int clientTeam = GetClientTeam(client);

	if (clientTeam == 2)
	{
		ProtectTeamSpawns(3);
	}
	else if (clientTeam == 3)
	{
		ProtectTeamSpawns(2);
	}	
}

public void Event_FlagPickup(Event event, const char[] name, bool dontBroadcast)
{
	//int cp = event.GetInt("cp");
	//int priority = event.GetInt("priority");
	int userid = event.GetInt("userid");
	//PrintToChatAll("flag_captured. cp: %d, priority: %d, userid: %d", cp, priority, userid);

	int client = GetClientOfUserId(userid);
	int clientTeam = GetClientTeam(client);

	ProtectTeamSpawns(clientTeam);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	// int teamnum = event.GetInt("teamnum");
	int userid = event.GetInt("userid");
	// PrintToChatAll("player_spawn. teamnum: %d, userid: %d", teamnum, userid);

	int client = GetClientOfUserId(userid);
	int clientTeam = GetClientTeam(client);

	int now = GetTime();
	_playerLastSpawnTimestamps[client] = now;

	if (_teamLastProtectedSpawnEventTimestamps[clientTeam] < 0 || now - _teamLastProtectedSpawnEventTimestamps[clientTeam] > 0)
	{
		return;
	}

	// PrintToChat(client, "This is a protected spawn.");
	_playerLastProtectedSpawnTimestamps[client] = now;
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	// int weaponid = event.GetInt("weaponid");
	int userid = event.GetInt("userid");
	// int shots = event.GetInt("shots");
	// PrintToChatAll("weapon_fire. weaponid: %d, userid: %d", shots: %d, weaponid, userid, shots);

	int client = GetClientOfUserId(userid);

	_playerLastWeaponFireTimestamps[client] = GetTime();
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

public int NullMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return 0;
}

public void ProtectTeamSpawns(int team)
{
	_teamLastProtectedSpawnEventTimestamps[team] = GetTime();

	int now = GetTime();
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == team && _playerLastSpawnTimestamps[i] > 0 && now - _playerLastSpawnTimestamps[i] <= 0)
		{
			// PrintToChat(i, "You are protected.");
			_playerLastProtectedSpawnTimestamps[i] = now;
		}
	}
}

public void ShowPanelMessage(int client, const char[] message)
{
	Panel panel = CreatePanel(INVALID_HANDLE);

	DrawPanelText(panel, message);
	SendPanelToClient(panel, client, NullMenuHandler, 2);
	CloseHandle(panel);
}