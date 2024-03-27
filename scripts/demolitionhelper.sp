#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.02"

int _bombPlantedByTeam = -1;
bool _isEnabled = false;
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

	HookEvent("controlpoint_starttouch", Event_ControlpointStartTouch);
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
		OnBombPlanted(teamWithBomb);
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

//
// Commands
//

//
// Hooks
//

public void Event_ControlpointStartTouch(Event event, const char[] name, bool dontBroadcast)
{
	int area = event.GetInt("area");
	//int obj = event.GetInt("object");
	//int owner = event.GetInt("owner");
	int playerClient = event.GetInt("player");
	//int team = event.GetInt("team");
	//int type = event.GetInt("type");
	//PrintToChatAll("\x05controlpoint_starttouch. area: %d, object: %d, owner: %d, player: %d, team: %d, type: %d", area, obj, owner, playerClient, team, type);

	if (!_isEnabled || IsFakeClient(playerClient))
	{
		return;
	}

	int playerTeam = GetClientTeam(playerClient);
	if (playerClient == GetEntityAncestor(GetBombEntity()))
	{
		if ((playerTeam == 2 && area == 2) || (playerTeam == 3 && area == 0))
		{
			PrintHintText(playerClient, "Look down at the bomb zone and hold the use key to plant the bomb.");
		}

		return;
	}

	if (_bombPlantedByTeam < 2)
	{
		return;
	}

	if (playerTeam != _bombPlantedByTeam)
	{
		PrintHintText(playerClient, "Look down at the bomb and hold the use key to diffuse the bomb.");
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!_isEnabled)
	{
		return;
	}

	_bombPlantedByTeam = -1;
	MarkBomb();
	PrintCenterTextAll("Get the bomb and plant it at the enemy's base!");
}

// 
// Helper Functions
//

public void OnBombDropped()
{
	PrintHintTextToAll("The bomb has been dropped!");

	MarkBomb();
}

public void OnBombPickedUp(int teamWithBomb)
{
	char[] yourTeamMessage = "Your team has picked up the bomb!";
	char[] enemyTeamMessage = "The enemy team has picked up the bomb! Defend your base.";
	PrintHintToPlayersByTeam(teamWithBomb == 2 ? yourTeamMessage : enemyTeamMessage, teamWithBomb == 3 ? yourTeamMessage : enemyTeamMessage);

	MarkPlantZone(teamWithBomb);
}

public void OnBombPlanted(int teamWithBomb)
{
	char[] yourTeamMessage = "Your team has planted the bomb! Don't let it get defused.";
	char[] enemyTeamMessage = "The enemy team has planted the bomb! Defuse it.";
	PrintHintToPlayersByTeam(teamWithBomb == 2 ? yourTeamMessage : enemyTeamMessage, teamWithBomb == 3 ? yourTeamMessage : enemyTeamMessage);

	_bombPlantedByTeam = teamWithBomb;
	MarkPlantZone(teamWithBomb);
}

//
// Helper Functions
//

public int GetBombEntity()
{
	return GetEntityByNameAndClassName("bomb", "prop_dynamic_override");
}

public int GetEntityAncestor(int entity)
{
	if (entity > -1)
	{
		int entityParent = -1;
		while ((entityParent = GetEntPropEnt(entity, Prop_Send, "moveparent")) != -1)
		{
			entity = entityParent;
		}
	}

	return entity;
}

public int GetEntityByNameAndClassName(const char[] entityName, const char[] entityClassName)
{
	int entity = -1;
	while((entity = FindEntityByClassname(entity, entityClassName)) != -1)
	{
		char eName[128];
		GetEntPropString(entity, Prop_Data, "m_iName", eName, sizeof(eName));

		if (StrEqual(entityName, eName))
		{
			break;
		}
	}

	return entity;
}

public void GetEntityPosition(int entity, float vector[3])
{
	GetEntPropVector(GetEntityAncestor(entity), Prop_Send, "m_vecOrigin", vector);
}

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

//
// Marker Functions
//

public void MarkBomb()
{
	int entityToMark = GetBombEntity();
	ShowMarker(entityToMark, "0 0 255");
}

public void MarkPlantZone(int teamWithBomb)
{
	int entityToMark = -1;
	if (teamWithBomb == 2)
	{
		entityToMark = GetEntityByNameAndClassName("Seal_Plant", "trigger_multiple");
	}
	else
	{
		entityToMark = GetEntityByNameAndClassName("Terrorist_Plant", "trigger_multiple");
	}

	if (_bombPlantedByTeam >= 2)
	{
		ShowMarker(entityToMark, "255 0 0");
	}
	else
	{
		ShowMarker(entityToMark, "255 255 0");
	}
}

public void HideMarker()
{
	int laserEntity = GetEntityByNameAndClassName("MarkerLaser", "env_laser");
	if (laserEntity == -1)
	{
		return;
	}

	AcceptEntityInput(laserEntity, "Kill");
}

public void ShowMarker(int entityToMark, const char[] renderColor)
{
	if (GetEntityByNameAndClassName("MarkerLaser", "env_laser") != -1)
	{
		HideMarker();
	}

	float laserPosition[3];
	GetEntityPosition(entityToMark, laserPosition);
	laserPosition[2] = laserPosition[2] + 800;

	char entityTargetName[128];
	GetEntPropString(entityToMark, Prop_Data, "m_iName", entityTargetName, sizeof(entityTargetName));

	int laserEntity = CreateEntityByName("env_laser");
	if (laserEntity == -1)
	{
		return;
	}

	DispatchKeyValue(laserEntity,"spawnflags", "49");
	DispatchKeyValue(laserEntity,"targetname", "MarkerLaser");
	DispatchKeyValue(laserEntity,"renderfx", "0");
	DispatchKeyValue(laserEntity,"LaserTarget", entityTargetName);
	DispatchKeyValue(laserEntity,"renderamt", "188");
	DispatchKeyValue(laserEntity,"rendercolor", renderColor);
	DispatchKeyValue(laserEntity,"Radius", "256");
	DispatchKeyValue(laserEntity,"life", "0");
	DispatchKeyValue(laserEntity,"width", "10");
	DispatchKeyValue(laserEntity,"NoiseAmplitude", "0");
	DispatchKeyValue(laserEntity,"texture", "sprites/laserbeam.spr");
	DispatchKeyValue(laserEntity,"TextureScroll", "100");
	DispatchKeyValue(laserEntity,"framerate", "0");
	DispatchKeyValue(laserEntity,"framestart", "0");
	DispatchKeyValue(laserEntity,"StrikeTime", "10");
	DispatchKeyValue(laserEntity,"damage", "0");
	DispatchSpawn(laserEntity);
	TeleportEntity(laserEntity, laserPosition, NULL_VECTOR, NULL_VECTOR);
}