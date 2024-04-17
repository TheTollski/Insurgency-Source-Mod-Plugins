#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.01"

public Plugin myinfo = 
{
	name = "All Chat",
	author = "Tollski",
	description = "",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

// Forwards
public void OnPluginStart()
{
	CreateConVar("sm_allchat_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	// PrintToChatAll("OnClientSayCommand. client %d, command '%s', sArgs '%s'", client, command, sArgs);

	if (client < 1 || !StrEqual(command, "say") || IsPlayerAlive(client))
	{
		return;
	}

	int clientTeam = GetClientTeam(client);

	char playerName[MAX_NAME_LENGTH];
	GetClientName(client, playerName, sizeof(playerName));

	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && i != client)
		{
			if (GetClientTeam(client) < 2) // Spectators can't seem to chat to eachother or to players.
			{
				PrintToChat(i, "*SPEC* %s : %s", playerName, sArgs);
			}
			else if (GetClientTeam(i) != clientTeam) // Dead players can't chat to the other team.
			{
				PrintToChat(i, "\x07a93f29*DEAD* %s : \x07ffffff%s", playerName, sArgs);
			}
		}
	}
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
