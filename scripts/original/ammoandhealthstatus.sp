#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

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

	HookEvent("round_start", Event_RoundStart);

  CreateTimer(0.5, UpdateAmmoAndHealthStatusesTimer, _, TIMER_REPEAT);
}

//
// Commands
//

//
// Hooks
//

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	PrintToChatAll("Round Start");

  for (int i = 1, iClients = GetClientCount(); i <= iClients; i++)
  {
    if (IsClientInGame(i) && !IsFakeClient(i))
    {
      // CreateDialog doesn't seem to be supported.
      // PrintToChat(i, "Showing dialog");
      // KeyValues kv = new KeyValues("hello", "title", "Press ESC To Type Input");
      // kv.SetString("msg", "Type your message here");
      // kv.SetString("command", "sm_something");
      // kv.SetNum("level", 1);
      // kv.SetNum("time", 200);
      // CreateDialog(i, kv, DialogType_Entry);
      // delete kv;


      //Hud text doesn't seem to be supported
      // PrintToChat(i, "Showing hud text");
      // SetHudTextParams(-1.0, -1.0, 5.0, 255, 0, 0, 255, 0, 0.25, 1.0, 1.0);
      // ShowHudText(i, -1, "This is a test %d", i);


      // Menus take up buttons and will close when those buttons are pressed.
      // PrintToChat(i, "Showing menu");
      // Menu menu = new Menu(Handle_Menu);
      // menu.SetTitle("Title");
      // menu.AddItem("yes", "Yes");
      // menu.ExitButton = false;
      // menu.Display(i, 9);


      // Panels have the same issues as menus.
      // PrintToChat(i, "Showing panel");
      // Panel panel = new Panel();
      // panel.SetTitle("Do you like apples?");
      // panel.DrawItem("Yes");
      // panel.DrawItem("No");
  
      // panel.Send(i, PanelHandler1, 20);
  
      // delete panel;
    }


  }
}

// 
// Helper Functions
//

public Action UpdateAmmoAndHealthStatusesTimer(Handle timer, DataPack inputPack)
{
  for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientConnected(i) && IsClientAuthorized(i) && !IsFakeClient(i) && IsPlayerAlive(i))
		{
			UpdateAmmoAndHealthStatus(i);
		}
	}
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
