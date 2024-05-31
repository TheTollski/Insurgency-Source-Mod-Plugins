#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.01"

public Plugin myinfo = 
{
	name = "Ammo and Health Status",
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
  CreateConVar("ammoandhealthstatus", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
  
  CreateTimer(0.5, UpdateAmmoAndHealthStatusesTimer, _, TIMER_REPEAT);
}

//
// Commands
//

//
// Hooks
//

// 
// Helper Functions
//

public Action UpdateAmmoAndHealthStatusesTimer(Handle timer, DataPack inputPack)
{
  for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && IsPlayerAlive(i))
		{
			UpdateAmmoAndHealthStatus(i);
		}
	}

  return Plugin_Handled;
}

public void UpdateAmmoAndHealthStatus(int client)
{
  int ammo = -1;
  int activeWeapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
  if (activeWeapon >= 0)
	{
    ammo = GetEntProp(activeWeapon, Prop_Data, "m_iClip1");
    if (GetEntData(activeWeapon, FindSendPropInfo("CINSWeaponBallistic", "m_bChamberedRound"), 1))
    {
      ammo++;
    }
  }

  int health = GetClientHealth(client);

  char ammoString[8];
  if (ammo >= 0)
  {
    Format(ammoString, sizeof(ammoString), "%d", ammo);
  }
  else
  {
    Format(ammoString, sizeof(ammoString), "-");
  }
	
  PrintHintText(client, "HP: %d | Ammo: %s", health, ammoString);
}
