#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

int _iNumbers[MAXPLAYERS + 1] = { 0, ... };

public Plugin myinfo = 
{
	name = "My First Plugin",
	author = "Tollski",
	description = "Does very basic stuff.",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

public void OnPluginStart()
{
	/**
	 * @note For the love of god, please stop using FCVAR_PLUGIN.
	 * Console.inc even explains this above the entry for the FCVAR_PLUGIN define.
	 * "No logic using this flag ever existed in a released game. It only ever appeared in the first hl2sdk."
	 */
	CreateConVar("sm_myfirstplugin_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	RegConsoleCmd("sm_testreply", Command_TestReply, "Replies 'test'.");
	
	RegConsoleCmd("sm_add", Command_Add, "Add two numbers.");
	
	RegConsoleCmd("sm_get", Command_Get, "Gets your number.");
	RegConsoleCmd("sm_set", Command_Set, "Sets your number.");
	
	RegConsoleCmd("sm_testmenu", Command_TestMenu, "Displays a test menu.");
	
	PrintToServer("hello world");

	ParseKeyValues();
}

public void OnClientPutInServer(int client)
{
	_iNumbers[client] = 0;
}

public void OnClientDisconnect(int client)
{
	_iNumbers[client] = 0;
}

public void OnMapStart()
{
	/**
	 * @note Precache your models, sounds, etc. here!
	 * Not in OnConfigsExecuted! Doing so leads to issues.
	 */
}

// Basic Command Tutorial
public Action Command_TestReply(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[SM] Usage: sm_testreply");
		return Plugin_Handled;
	}
	
	ReplyToCommand(client, "test");
	return Plugin_Handled;
}

// Add Tutorial
public Action Command_Add(int client, int args)
{
	if (args != 2) {
		ReplyToCommand(client, "[SM] Usage: sm_add <number1> <number2>");
		return Plugin_Handled;
	}
	
	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	char arg2[32];
	GetCmdArg(2, arg2, sizeof(arg2));
	
	int num1 = StringToInt(arg1);
	int num2 = StringToInt(arg2);
	
	ReplyToCommand(client, "[SM] Your sum is: %d", num1 + num2);
	return Plugin_Handled;
}

// Player Variables Tutorial
public Action Command_Get(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[SM] Usage: sm_get");
		return Plugin_Handled;
	}
	
	ReplyToCommand(client, "[SM] Your number is: %d", _iNumbers[client]);
	return Plugin_Handled;
}

public Action Command_Set(int client, int args)
{
	if (args != 1) {
		ReplyToCommand(client, "[SM] Usage: sm_set <number>");
		return Plugin_Handled;
	}
	
	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	int num = StringToInt(arg1);
	_iNumbers[client] = num;
	
	ReplyToCommand(client, "[SM] Number %d was successfully set.", num);
	return Plugin_Handled;
}

// Menu Tutorial
public Action Command_TestMenu(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[SM] Usage: sm_testmenu");
		return Plugin_Handled;
	}
	
	Menu menu = new Menu(MenuCallback);
	menu.SetTitle("Test Menu :)");
	menu.AddItem("option1", "Security Team Option", GetClientTeam(client) == 2 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("option2", "Any Team Option");
	menu.Display(client, 30);
	
	return Plugin_Handled;
}

public int MenuCallback(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char selectedItem[32];
			menu.GetItem(param2, selectedItem, sizeof(selectedItem));
			
			if (StrEqual(selectedItem, "option1"))
			{
				
			}
			else if (StrEqual(selectedItem, "option2"))
			{
				
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
}

// Key Values Tutorial
public void ParseKeyValues()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/myfirstplugin.cfg");

	if (!FileExists(path))
	{
		SetFailState("Configuration file '%s' is not found.", path);
		return;
	}

	KeyValues keyValues = new KeyValues("Weapons");
	if (!keyValues.ImportFromFile(path))
	{
		SetFailState("Unable to parse Key Values file '%s'.", path);
		return;
	}

	if (!keyValues.JumpToKey("Rifles"))
	{
		SetFailState("Unable to find Rifles section in file '%s'.", path);
		return;
	}

	if (!keyValues.GotoFirstSubKey())
	{
		SetFailState("Unable to find subkeys in Rifles section in file '%s'.", path);
		return;
	}

	do
	{
		char entity[100];
		char name[32];
		char team[32];

		keyValues.GetSectionName(entity, sizeof(entity));
		keyValues.GetString("name", name, sizeof(name));
		keyValues.GetString("team", team, sizeof(team));

		PrintToServer("%s - %s - %s", entity, name, team);
	}
	while(keyValues.GotoNextKey());

	keyValues.Rewind();

	if (!keyValues.JumpToKey("Pistols"))
	{
		SetFailState("Unable to find Pistols section in file '%s'.", path);
		return;
	}

	if (!keyValues.GotoFirstSubKey())
	{
		SetFailState("Unable to find subkeys in Pistols section in file '%s'.", path);
		return;
	}

	do
	{
		char entity[100];
		char name[32];
		char team[32];

		keyValues.GetSectionName(entity, sizeof(entity));
		keyValues.GetString("name", name, sizeof(name));
		keyValues.GetString("team", team, sizeof(team));

		PrintToServer("%s - %s - %s", entity, name, team);
	}
	while(keyValues.GotoNextKey());

	delete keyValues;
}