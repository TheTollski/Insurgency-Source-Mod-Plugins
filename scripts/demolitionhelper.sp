#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.01"

bool _isEnabled = false;
int _laserEntity = -1;
int _normalMpIgnoreWinConditionsValue;

public Plugin myinfo = 
{
	name = "Demolition Helper",
	author = "Tollski",
	description = "",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

// Forwards
public void OnPluginStart()
{
	CreateConVar("sm_demolitionhelper_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	HookEvent("round_start", Event_RoundStart);
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if (!_isEnabled || client != 0 || !StrEqual(command, "say", false))
	{
		return;
	}

	if (StrContains(sArgs, "HAVE PICKED UP THE BOMB!", false) >= 0)
	{
		int teamWithBomb = StrContains(sArgs, "SEALS", false) >= 0 ? 2 : 3;
		OnBombPickedUp(teamWithBomb);
	}

	if (StrContains(sArgs, "HAVE PLANTED THE BOMB!", false) >= 0)
	{
		int teamWithBomb = StrContains(sArgs, "SEALS", false) >= 0 ? 2 : 3;
		char[] yourTeamMessage = "Your team has planted the bomb! Don't let it get defused.";
		char[] enemyTeamMessage = "The enemy team has planted the bomb! Defuse it.";
		PrintHintToPlayersByTeam(teamWithBomb == 2 ? yourTeamMessage : enemyTeamMessage, teamWithBomb == 3 ? yourTeamMessage : enemyTeamMessage);
	}

	if (StrEqual(sArgs, "THE BOMB HAS BEEN DROPPED!", false))
	{
		OnBombDropped();
	}
}

public void OnMapEnd()
{
	if (!_isEnabled)
	{
		return;
	}

	// Ensure any ConVar changes made by the map are reverted.
	ConVar mpIgnoreWinConditionsConVar = FindConVar("mp_ignore_win_conditions");
	mpIgnoreWinConditionsConVar.IntValue = _normalMpIgnoreWinConditionsValue;
} 

public void OnMapStart()
{
	char mapName[64];
	int bytesWritten = GetCurrentMap(mapName, sizeof(mapName));
	if (bytesWritten == 0) {
		PrintToServer("[Demolition Helper] Unable to get current map name.");
		return;
	}
	
	_isEnabled = StrContains(mapName, "_demolition_", false) >= 0;

	if (!_isEnabled)
	{
		return;
	}

	ConVar mpIgnoreWinConditionsConVar = FindConVar("mp_ignore_win_conditions");
	_normalMpIgnoreWinConditionsValue = mpIgnoreWinConditionsConVar.IntValue;
}

// Commands

// Hooks

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!_isEnabled)
	{
		return;
	}
	
	PrintCenterTextAll("Get the bomb and plant it at the enemy's base!");
	MarkBomb();
}

// 

// Helper Functions

public void PrintHintToPlayersByTeam(const char[] textToPrintToSecurity, const char[] textToPrintToInsurgents)
{
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			int team = GetClientTeam(i);
			if (team == 2)
			{
				PrintHintText(i, textToPrintToSecurity);
			}
			else if (team == 3)
			{
				PrintHintText(i, textToPrintToInsurgents);
			}
		}
	}
}

public void OnBombDropped()
{
	PrintHintTextToAll("The bomb has been dropped!");

	MarkBomb();
}

public void OnBombPickedUp(int teamWithBomb)
{
	char[] yourTeamMessage = "Your team has picked up the bomb!";
	char[] enemyTeamMessage = "The enemy team has picked up the bomb!";
	PrintHintToPlayersByTeam(teamWithBomb == 2 ? yourTeamMessage : enemyTeamMessage, teamWithBomb == 3 ? yourTeamMessage : enemyTeamMessage);

	UnmarkBomb();
}

public int GetEntityByNameAndClassName(const char[] entityName, const char[] entityClassName)
{
	int entity = -1;
	while((entity = FindEntityByClassname(entity, entityClassName)) != -1)
	{
		char eName[32];
		GetEntPropString(entity, Prop_Data, "m_iName", eName, sizeof(eName));

		if (StrEqual(entityName, eName))
		{
			break;
		}
	}

	return entity;
}

public void MarkBomb()
{
	if (_laserEntity != -1)
	{
		UnmarkBomb();
	}

	int bombEntity = GetEntityByNameAndClassName("bomb", "prop_dynamic_override");
	if (bombEntity > -1)
	{
		int entityToGetPosition = bombEntity;
		int entityParent = -1;
		while ((entityParent = GetEntPropEnt(entityToGetPosition, Prop_Send, "moveparent")) != -1)
		{
			entityToGetPosition = entityParent;
		}

		float laserPosition[3];
		GetEntPropVector(entityToGetPosition, Prop_Send, "m_vecOrigin", laserPosition);
		laserPosition[2] = laserPosition[2] + 800;

		_laserEntity = CreateEntityByName("env_laser");
		if (_laserEntity == -1)
		{
			return;
		} 

		DispatchKeyValue(_laserEntity,"spawnflags", "49");
		DispatchKeyValue(_laserEntity,"targetname", "my_laser");
		DispatchKeyValue(_laserEntity,"renderfx", "0");
		DispatchKeyValue(_laserEntity,"LaserTarget", "bomb");
		DispatchKeyValue(_laserEntity,"renderamt", "188");
		DispatchKeyValue(_laserEntity,"rendercolor", "255 0 0");
		DispatchKeyValue(_laserEntity,"Radius", "256");
		DispatchKeyValue(_laserEntity,"life", "0");
		DispatchKeyValue(_laserEntity,"width", "10");
		DispatchKeyValue(_laserEntity,"NoiseAmplitude", "0");
		DispatchKeyValue(_laserEntity,"texture", "sprites/laserbeam.spr");
		DispatchKeyValue(_laserEntity,"TextureScroll", "100");
		DispatchKeyValue(_laserEntity,"framerate", "0");
		DispatchKeyValue(_laserEntity,"framestart", "0");
		DispatchKeyValue(_laserEntity,"StrikeTime", "10");
		DispatchKeyValue(_laserEntity,"damage", "0");
		DispatchSpawn(_laserEntity);
		TeleportEntity(_laserEntity, laserPosition, NULL_VECTOR, NULL_VECTOR);
	}
}

public void UnmarkBomb()
{
	if (_laserEntity == -1)
	{
		return;
	}

	AcceptEntityInput(_laserEntity, "Kill");
	_laserEntity = -1;
}
