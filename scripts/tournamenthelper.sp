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
// Unlock server if empty or game is too long.

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
		int allowedTeam = GetPlayerAllowedTeam(client);

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

	int currentPlayersOnInsurgents = GetPlayerCountOnTeam(3);
	int currentPlayersOnSecurity = GetPlayerCountOnTeam(2);
	ReplyToCommand(client, "[Tournament Helper] ins %d, sec %d", currentPlayersOnInsurgents, currentPlayersOnSecurity);

	if (currentPlayersOnSecurity == 0 || currentPlayersOnInsurgents == 0)
	{
		// ReplyToCommand(client, "[Tournament Helper] Failed to start vote; both teams must have players.");
		// return Plugin_Handled;
	}

	if (IsVoteInProgress())
	{
		ReplyToCommand(client, "\x07[Tournament Helper] Failed to start vote; another vote is already in progress.");
		return Plugin_Handled;
	}

	ReplyToCommand(client, "\x05[Tournament Helper] Initiating vote.");

	char requestorName[MAX_NAME_LENGTH];
	GetClientName(client, requestorName, sizeof(requestorName));

	SetIsMatchInProgess(true);
	_currentVoteType = 1;

	Menu menu = new Menu(Handle_VoteMenu);
	menu.VoteResultCallback = Handle_VoteResults;
	menu.SetTitle("'%s' has initiated a vote to start the match. Is your team ready?", requestorName);
	// menu.SetTitle("Change map to: %s?", map);
	// menu.AddItem(map, "Yes");
	// menu.AddItem("no", "No");
	menu.AddItem("yes", "Yes");
	menu.AddItem("no", "No");
	menu.ExitButton = false;
	menu.DisplayVoteToAll(10);

	return Plugin_Handled;
}

//
// Hooks
//

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	// int oldteam = event.GetInt("oldteam");
	
	// PrintToChatAll("Player Team Event. userid: %d, team: %d, oldteam: %d.", userid, team, oldteam);

	int client = GetClientOfUserId(userid);
	if (IsFakeClient(client) || !_isMatchInProgess)
	{
		return;
	}

	int allowedTeam = GetPlayerAllowedTeam(client);
	if (allowedTeam != team)
	{
		DataPack pack = new DataPack();
		pack.WriteCell(client);
		pack.WriteCell(allowedTeam);
		CreateTimer(0.25, PlayerTeamEvent_ChangeClientTeam_AfterDelay, pack);
	}
}

public Action PlayerTeamEvent_ChangeClientTeam_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	int allowedTeam = inputPack.ReadCell();
	CloseHandle(inputPack);

	PrintToChat(client, "You are being moved to your designated team.");
	ChangeClientTeam(client, allowedTeam);
}

//
// Helper Functions
//

public int GetPlayerAllowedTeam(int playerClient)
{
	char authId[35];
	GetClientAuthId(playerClient, AuthId_Steam2, authId, sizeof(authId));

	for (int i = 0; i < _playerCount; i++)
	{
		if (StrEqual(authId, _playerAuthIdInfo[i]))
		{
			return _playerTeamInfo[i];
		}
	}

	return -1;
}

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

public void SetIsMatchInProgess(bool isMatchInProgress)
{
	if (isMatchInProgress == _isMatchInProgess)
	{
		return;
	}

	PrintToChatAll("[Tournament Helper] Setting _isMatchInProgess to %d", isMatchInProgress);


	_isMatchInProgess = isMatchInProgress;
	_playerCount = 0;

	for (int i = 1; i < MaxClients + 1; i++)
	{
		_playerAuthIdInfo[i] = "";
		_playerTeamInfo[i] = -1;

		if (!isMatchInProgress)
		{
			continue;
		}

		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			char authId[35];
			GetClientAuthId(i, AuthId_Steam2, authId, sizeof(authId));
			
			_playerAuthIdInfo[_playerCount] = authId;
			_playerTeamInfo[_playerCount] = GetClientTeam(i);

			_playerCount++;
		}
	}
}

// Vote Helper Functions

public int Handle_VoteMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		PrintToChatAll("[Tournament Helper] Handle_VoteMenu. action MenuAction_End");
		/* This is called after VoteEnd */
		delete menu;

		_currentVoteType = 0;
	}
	if (action == MenuAction_Cancel)
	{
		PrintToChatAll("[Tournament Helper] Handle_VoteMenu. action MenuAction_Cancel");
	}
	if (action == MenuAction_VoteCancel)
	{
		PrintToChatAll("[Tournament Helper] Handle_VoteMenu. action MenuAction_VoteCancel");
		SetIsMatchInProgess(false);
	}
	if (action == MenuAction_VoteEnd)
	{
		PrintToChatAll("[Tournament Helper] Handle_VoteMenu. action MenuAction_VoteEnd");
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
		PrintToChatAll("[Tournament Helper] client[%d], index %d, item %d", i, client_info[i][VOTEINFO_CLIENT_INDEX], client_info[i][VOTEINFO_CLIENT_ITEM]);
	}

	for (int i = 0; i < num_items; i++)
	{
		char item[64];
		menu.GetItem(item_info[i][VOTEINFO_ITEM_INDEX], item, sizeof(item));
		PrintToChatAll("[Tournament Helper] item[%d], index %d, votes %d, value %s", i, item_info[i][VOTEINFO_ITEM_INDEX], item_info[i][VOTEINFO_ITEM_VOTES], item);
	}

	if (_currentVoteType == 1) // Ready Vote
	{
		int yesItemIndex = -1;
		for (int i = 0; i < num_items; i++)
		{
			char item[64];
			menu.GetItem(item_info[i][VOTEINFO_ITEM_INDEX], item, sizeof(item));
			if (StrEqual(item, "yes"))
			{
				yesItemIndex = item_info[i][VOTEINFO_ITEM_INDEX];
				break;
			}
		}

		// Verify yes from each player on a team.
		for (int i = 0; i < _playerCount; i++)
		{
			if (_playerTeamInfo[i] != 2 && _playerTeamInfo[i] != 3)
			{
				continue;
			}

			// Get vote for player.
			int playerVoteItemIndex = -2;
			for (int j = 0; j < num_clients; j++)
			{
				char authId[35];
				GetClientAuthId(client_info[j][VOTEINFO_CLIENT_INDEX], AuthId_Steam2, authId, sizeof(authId));

				PrintToChatAll("[Tournament Helper] Checking %s vs %s", authId, _playerAuthIdInfo[i]);
				if (StrEqual(authId, _playerAuthIdInfo[i]))
				{
					playerVoteItemIndex = client_info[j][VOTEINFO_CLIENT_ITEM];

					char playerName[64];
					GetClientName(client_info[j][VOTEINFO_CLIENT_INDEX], playerName, sizeof(playerName));
					char item[64];
					menu.GetItem(client_info[j][VOTEINFO_CLIENT_ITEM], item, sizeof(item));
					PrintToChatAll("[Tournament Helper] %s voted %s", playerName, item);
				}
			}

			if (playerVoteItemIndex < 0 || playerVoteItemIndex != yesItemIndex)
			{
				SetIsMatchInProgess(false);
				return;
			}
		}
	}
}
