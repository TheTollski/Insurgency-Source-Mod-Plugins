#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.04"

const int OVERRIDE_MESSAGE_COUNT_MAX = 10;
const int OVERRIDE_MESSAGE_DIFFUSE = 11;
const int OVERRIDE_MESSAGE_PLANT = 12;

int _bombPickedUpByTeam = -1;
int _bombPlantedByTeam = -1;
int _entityToMark = -1;
bool _isEnabled = false;
int _normalMpIgnoreWinConditionsValue;
int _overrideMessages[MAXPLAYERS + 1] = { -1, ... };

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

	HookEvent("controlpoint_endtouch", Event_ControlpointEndTouch);
	HookEvent("controlpoint_starttouch", Event_ControlpointStartTouch);
	HookEvent("round_start", Event_RoundStart);

	CreateTimer(0.5, UpdateTipTimer, _, TIMER_REPEAT);
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if (!_isEnabled || client != 0 || !StrEqual(command, "say", false))
	{
		return Plugin_Handled;
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

	return Plugin_Handled;
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

public void Event_ControlpointEndTouch(Event event, const char[] name, bool dontBroadcast)
{
	//int area = event.GetInt("area");
	//int obj = event.GetInt("object");
	//int owner = event.GetInt("owner");
	int playerClient = event.GetInt("player");
	//int team = event.GetInt("team");
	//int type = event.GetInt("type");
	//PrintToChatAll("\x05controlpoint_endtouch. area: %d, object: %d, owner: %d, player: %d, team: %d, type: %d", area, obj, owner, playerClient, team, type);

	if (!_isEnabled || IsFakeClient(playerClient))
	{
		return;
	}

	if (_overrideMessages[playerClient] == OVERRIDE_MESSAGE_DIFFUSE || _overrideMessages[playerClient] == OVERRIDE_MESSAGE_PLANT)
	{
		_overrideMessages[playerClient] = -1;
	}
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

	if (!_isEnabled || IsFakeClient(playerClient))
	{
		return;
	}

	int playerTeam = GetClientTeam(playerClient);
	if (playerClient == GetEntityAncestor(GetBombEntity()))
	{
		if ((playerTeam == 2 && area == 2) || (playerTeam == 3 && area == 0))
		{
			_overrideMessages[playerClient] = OVERRIDE_MESSAGE_PLANT;
		}

		return;
	}

	if (_bombPlantedByTeam < 2)
	{
		return;
	}

	if (playerTeam != _bombPlantedByTeam)
	{
		_overrideMessages[playerClient] = OVERRIDE_MESSAGE_DIFFUSE;
	}
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!_isEnabled)
	{
		return;
	}

	for (int i = 1; i < MaxClients + 1; i++)
	{
		_overrideMessages[i] = -1;
	}

	_bombPickedUpByTeam = -1;
	_bombPlantedByTeam = -1;
	MarkBomb();
}

//
// Helper Functions
//

public void OnBombDropped()
{
	PrintCenterTextAll("The bomb has been dropped!");

	_bombPickedUpByTeam = -1;
	MarkBomb();
}

public void OnBombPickedUp(int teamWithBomb)
{
	char[] yourTeamMessage = "Your team has picked up the bomb!";
	char[] enemyTeamMessage = "The enemy team has picked up the bomb! Defend your base.";
	PrintTipToPlayersByTeam(teamWithBomb == 2 ? yourTeamMessage : enemyTeamMessage, teamWithBomb == 3 ? yourTeamMessage : enemyTeamMessage);

	_bombPickedUpByTeam = teamWithBomb;
	MarkPlantZone(teamWithBomb);
}

public void OnBombPlanted(int teamWithBomb)
{
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (_overrideMessages[i] == OVERRIDE_MESSAGE_PLANT)
		{
			_overrideMessages[i] = -1;
		}
	}

	char[] yourTeamMessage = "Your team has planted the bomb! Don't let it get defused.";
	char[] enemyTeamMessage = "The enemy team has planted the bomb! Defuse it.";
	PrintTipToPlayersByTeam(teamWithBomb == 2 ? yourTeamMessage : enemyTeamMessage, teamWithBomb == 3 ? yourTeamMessage : enemyTeamMessage);

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

public void PrintTipToPlayersByTeam(const char[] textToPrintToSecurity, const char[] textToPrintToInsurgents)
{
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			int team = GetClientTeam(i);
			if (team == 2)
			{
				_overrideMessages[i] = 6;
				PrintCenterText(i, textToPrintToSecurity);
			}
			else if (team == 3)
			{
				_overrideMessages[i] = 6;
				PrintCenterText(i, textToPrintToInsurgents);
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
	_entityToMark = -1;

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

	_entityToMark = entityToMark;

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

	DispatchKeyValue(laserEntity,"spawnflags", "1"); // 1: Start On
	DispatchKeyValue(laserEntity,"targetname", "MarkerLaser");
	DispatchKeyValue(laserEntity,"LaserTarget", entityTargetName);
	DispatchKeyValue(laserEntity,"renderamt", "150");
	DispatchKeyValue(laserEntity,"rendercolor", renderColor);
	DispatchKeyValue(laserEntity,"width", "10");
	DispatchKeyValue(laserEntity,"NoiseAmplitude", "0");
	DispatchKeyValue(laserEntity,"texture", "sprites/laserbeam.spr");
	DispatchKeyValue(laserEntity,"TextureScroll", "100");
	DispatchKeyValue(laserEntity,"damage", "0");
	DispatchSpawn(laserEntity);
	TeleportEntity(laserEntity, laserPosition, NULL_VECTOR, NULL_VECTOR);
}

public Action UpdateTipTimer(Handle timer, DataPack inputPack)
{
	if (_entityToMark < 0)
	{
		return Plugin_Continue;
	}

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (_overrideMessages[i] > 0 && _overrideMessages[i] <= OVERRIDE_MESSAGE_COUNT_MAX)
		{
			_overrideMessages[i] -= 1;
			continue;
		}
		if (_overrideMessages[i] == OVERRIDE_MESSAGE_DIFFUSE)
		{
			PrintCenterText(i, "Look down at the bomb and hold the use key to diffuse the bomb.");
			continue;
		}
		if (_overrideMessages[i] == OVERRIDE_MESSAGE_PLANT)
		{
			PrintCenterText(i, "Look down at the bomb zone and hold the use key to plant the bomb.");
			continue;
		}

		if (IsClientInGame(i) && !IsFakeClient(i) && IsPlayerAlive(i))
		{
			float playerPosition[3];
			GetClientEyePosition(i, playerPosition);

			float entityPosition[3];
			GetEntityPosition(_entityToMark, entityPosition);

			char action[17];
			int team = GetClientTeam(i);
			if (_bombPlantedByTeam > -1)
			{
				if (team == _bombPlantedByTeam)
				{
					action = "Prevent Diffuse";
				}
				else
				{
					action = "Diffuse";
				}
			}
			else if (_bombPickedUpByTeam > -1)
			{
				if (team == _bombPickedUpByTeam)
				{
					if (i == GetEntityAncestor(GetBombEntity()))
					{
						action = "Plant";
					}
					else
					{
						action = "Assist Plant";
					}
				}
				else
				{
					action = "Prevent Plant";
				}
			}
			else
			{
				action = "Pickup";
			}

			float distance = GetVectorDistance(entityPosition, playerPosition, false) / 38.0;

			float dx = entityPosition[0] - playerPosition[0];
			float dy = entityPosition[1] - playerPosition[1];
			// float dz = entityPosition[2] - playerPosition[2];

			char xDir[2];
			if (dx > 50)
			{
				xDir = "E";
			}
			else if (dx < 50)
			{
				xDir = "W";
			}
			else
			{
				xDir = "";
			}

			char yDir[2] = "";
			if (dy > 50)
			{
				yDir = "N";
			}
			else if (dy < 50)
			{
				yDir = "S";
			}
			else
			{
				yDir = "";
			}

			// float playerViewAngle[3];
			// GetClientEyeAngles(i, playerViewAngle);
			// PrintCenterText(i, "%.1fm %s%s (%.1f, %.1f, %.1f) (%.1f, %.1f, %.1f)", distance, yDir, xDir, dx, dy, dz, playerViewAngle[0], playerViewAngle[1], playerViewAngle[2]);

			PrintCenterText(i, "%s | %.1fm %s%s", action, distance, yDir, xDir);
		}
	}

	return Plugin_Continue;
}