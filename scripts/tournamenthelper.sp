#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.00"

int _currentVoteType = 0; // 1 = Ready
bool _isMatchInProgess = false;
char _playerAuthIdInfo[MAXPLAYERS + 1][35];
int _playerCount = 0;
int _playerTeamInfo[MAXPLAYERS + 1] = { -1, ... };

// TODO:
// Disable voting on maps and stuff
// Respawn mode while match not in progress
// Voting to start match ()
// Tracking match results
// Enforce no team swapping while match not in progress
// Point system?

public Plugin myinfo =
{
	name = "Tournament Helper",
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
	CreateConVar("sm_tournamenthelper_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	RegConsoleCmd("sm_startvote", Command_StartVote, "Starts the voting process.");

	AddCommandListener(Command_Jointeam, "jointeam");

	HookEvent("player_team", Event_PlayerTeam);
}

public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}
	
}

public void OnMapStart()
{

}

public Action Command_Jointeam(int client, const char[] command, int args)
{
	char team[8];
	GetCmdArg(1, team, sizeof(team));
	int iTeam = StringToInt(team);

	// PrintToChat(client, "command %s, team %d", command, iTeam);

	if (_isMatchInProgess)
	{
		char authId[35];
		GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));

		int allowedTeam = -1;
		for (int i = 0; i < _playerCount; i++)
		{
			// PrintToChat(client, "authId %s, _playerAuthIdInfo[%d] %s", authId, i, _playerAuthIdInfo[i]);
			if (StrEqual(authId, _playerAuthIdInfo[i]))
			{
				allowedTeam = _playerTeamInfo[i];
				continue;
			}
		}

		// PrintToChat(client, "_playerCount %d, allowedTeam %d", _playerCount, allowedTeam);

		if (allowedTeam != iTeam)
		{
			PrintToChat(client, "You cannot currently join that team.");
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
} 

public Action Command_StartVote(int client, int args)
{
	if (args > 0) {
		ReplyToCommand(client, "\x07[Tournament Helper] Usage: sm_startvote");
		return Plugin_Handled;
	}
	
	if (_isMatchInProgess)
	{
		ReplyToCommand(client, "\x07[Tournament Helper] Failed to start vote; a match is already in progress.");
		return Plugin_Handled;
	}

	if (IsVoteInProgress())
	{
		ReplyToCommand(client, "\x07[Tournament Helper] Failed to start vote; another vote is already in progress.");
		return Plugin_Handled;
	}

	int currentPlayersOnInsurgents = GetPlayerCountOnTeam(3);
	int currentPlayersOnSecurity = GetPlayerCountOnTeam(2);
	ReplyToCommand(client, "[Tournament Helper] ins %d, sec %d", currentPlayersOnInsurgents, currentPlayersOnSecurity);

	if (currentPlayersOnSecurity == 0 || currentPlayersOnInsurgents == 0)
	{
		// ReplyToCommand(client, "[Tournament Helper] Failed to start vote; both teams must have players.");
		// return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Tournament Helper] Initiating vote.");

	char requestorName[MAX_NAME_LENGTH];
	GetClientName(client, requestorName, sizeof(requestorName));

	_currentVoteType = 0;
	_isMatchInProgess = true;
	_playerCount = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		_playerAuthIdInfo[i] = "";
		_playerTeamInfo[i] = -1;
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			char authId[35];
			GetClientAuthId(i, AuthId_Steam2, authId, sizeof(authId));
			
			_playerAuthIdInfo[_playerCount] = authId;
			_playerTeamInfo[_playerCount] = GetClientTeam(i);

			_playerCount++;
		}
	}

	Menu menu = new Menu(Handle_VoteMenu);
	menu.VoteResultCallback = Handle_VoteResults;
	menu.SetTitle("'%s' has initiated a vote. Are you ready?", requestorName);
	// menu.SetTitle("Change map to: %s?", map);
	// menu.AddItem(map, "Yes");
	// menu.AddItem("no", "No");
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = false;
	menu.DisplayVoteToAll(5);

	return Plugin_Handled;
}

//
// Hooks
//

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	int oldteam = event.GetInt("oldteam");
	
	PrintToChatAll("Player Team Event. userid: %d, team: %d, oldteam: %d.", userid, team, oldteam);

	int client = GetClientOfUserId(userid);
	bool isRealPlayer = !IsFakeClient(client);
	
	// if (isRealPlayer)
	// {
	// 	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(oldteam, team);
		
	// 	return;
	// }

	// if (!_botStackingIsEnabled || team < 2)
	// {
	// 	return;
	// }
	
	// DataPack pack = new DataPack();
	// pack.WriteCell(client);
	// pack.WriteCell(team);
		
	// CreateTimer(0.25, PlayerTeamEvent_Bot_AfterDelay, pack);
}

//
// Helper Functions
//

public int GetPlayerCountOnEitherTeam()
{
	return GetPlayerCountOnTeam(2) + GetPlayerCountOnTeam(3);
}

public int GetPlayerCountOnTeam(int team)
{
	int count = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
		{
			count++;
		}
	}

	return count;
}

public int Handle_VoteMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		/* This is called after VoteEnd */
		delete menu;

		_currentVoteType = 0;
	}
}
 
public void Handle_VoteResults(
	Menu menu, 
  int num_votes, 
  int num_clients, 
  const int[][] client_info, 
  int num_items, 
  const int[][] item_info)
{
	/* See if there were multiple winners */
	// int winner = 0;
	// if (num_items > 1 && (item_info[0][VOTEINFO_ITEM_VOTES] == item_info[1][VOTEINFO_ITEM_VOTES]))
	// {
	//   winner = GetRandomInt(0, 1);
	// }

	// char map[64];
	// menu.GetItem(item_info[winner][VOTEINFO_ITEM_INDEX], map, sizeof(map));
	// ServerCommand("changelevel %s", map);
	PrintToChatAll("[Tournament Helper] Handle_VoteResults. num_votes %d, num_clients %d, num_items %d", num_votes, num_clients, num_items);

	for (int i = 0; i < num_clients; i++)
	{
		PrintToChatAll("[Tournament Helper] client %d, %d, %d", i, client_info[i][VOTEINFO_CLIENT_INDEX], client_info[i][VOTEINFO_CLIENT_ITEM]);
	}

	for (int i = 0; i < num_items; i++)
	{
		PrintToChatAll("[Tournament Helper] item %d, %d, %d", i, item_info[i][VOTEINFO_ITEM_INDEX], item_info[i][VOTEINFO_ITEM_VOTES]);
	}

	if (_currentVoteType == 1) // Ready Vote
	{
		// Verify yes from each player on a team and 0 nos from any other players.
		for (int i = 1; i < MaxClients + 1; i++)
		{
			// _playerAuthIdInfo[i] = ""
			// _playerTeamInfo[i] = -1;
			// if (IsClientInGame(i) && !IsFakeClient(i))
			// {
			// 		char authId[35];
			// 		GetClientAuthId(client, AuthId_Steam2, authId, sizeof(authId));
			// 		strcopy(authId, sizeof(authId), _playerAuthIdInfo[i]);

			// 	_playerTeamInfo[i] = GetClientTeam(i);
			// }
		}
	}
}
