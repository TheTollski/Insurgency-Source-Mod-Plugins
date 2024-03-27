#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.01"

bool _balancingIsActive = false;
int _botQuota = 0;
int _playerTeam = 0;

bool _clientsRealPlayerStatus[MAXPLAYERS + 1] = { false, ... };

public Plugin myinfo = 
{
	name = "Bot Balancer",
	author = "Tollski",
	description = "Stacks bots against player until multiple people connect to server.",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

// Forwards
public void OnPluginStart()
{
	CreateConVar("sm_botbalancer_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	HookEvent("player_team", Event_PlayerTeam);
}

public void OnClientPutInServer(int client)
{	
	bool isRealPlayer = !IsFakeClient(client);
	_clientsRealPlayerStatus[client] = isRealPlayer;
	
	if (!isRealPlayer)
	{
		return;
	}
	
	int realPlayerCount = GetRealPlayerCount();
	if (realPlayerCount == 1)
	{
		ExactlyOneRealPlayerIsInGame();
	}
	else if (realPlayerCount > 1)
	{
		MoreThanOneRealPlayerIsInGame();
	}
}

public void OnClientDisconnect(int client)
{
	bool wasRealPlayer = _clientsRealPlayerStatus[client];
	_clientsRealPlayerStatus[client] = false;
	
	if (!wasRealPlayer)
	{
		return;
	}
	
	int realPlayerCount = GetRealPlayerCount();
	if (realPlayerCount == 1)
	{
		ExactlyOneRealPlayerIsInGame();
	}
	else if (realPlayerCount > 1)
	{
		MoreThanOneRealPlayerIsInGame();
	}
}

public void OnMapStart()
{

}

// Event Hooks
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	if (!_balancingIsActive)
	{
		return;
	}
	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	
	int client = GetClientOfUserId(userid);

	bool isRealPlayer = !IsFakeClient(client);
	
	if (team < 2)
	{
		return;
	}
	
	if (isRealPlayer)
	{
		_playerTeam = team;
		int playerTeamCountWithoutThisClient = GetTeamClientCount(team);
		if (playerTeamCountWithoutThisClient >= 2)
		{
			KickXBotsFromTeam(team, playerTeamCountWithoutThisClient - 1);
		}
		
		return;
	}
	
	if (team == _playerTeam)
	{
		int playerTeamCountWithoutThisClient = GetTeamClientCount(team);
		if (playerTeamCountWithoutThisClient >= 2)
		{
			KickClient(client);
		}
	}
}

// Helper Functions
public void ExactlyOneRealPlayerIsInGame()
{
	if (_balancingIsActive)
	{
		return;
	}
	
	PrintToServer("ExactlyOneRealPlayerIsInGame");
	_balancingIsActive = true;
	
	ConVar insBotQuotaConVar = FindConVar("ins_bot_quota");
	PrintToServer("Changing ins_bot_quota from %d to 8.", insBotQuotaConVar.IntValue);
	_botQuota = insBotQuotaConVar.IntValue;
	insBotQuotaConVar.IntValue = 8;
	
	ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
	PrintToServer("Changing mp_teams_unbalance_limit from %d to 0.", mpTeamsUnbalanceLimitConVar.IntValue);
	mpTeamsUnbalanceLimitConVar.IntValue = 0;
	
	for (int i = 0; i < sizeof(_clientsRealPlayerStatus); i++)
	{
		if (_clientsRealPlayerStatus[i])
		{
			_playerTeam = GetClientTeam(i);
			int playerTeamCount = GetTeamClientCount(_playerTeam);
			if (playerTeamCount > 2)
			{
				KickXBotsFromTeam(_playerTeam, playerTeamCount - 1);
			}
		}
	}
}

public void MoreThanOneRealPlayerIsInGame()
{
	if (!_balancingIsActive)
	{
		return;
	}
	
	PrintToServer("MoreThanOneRealPlayerIsInGame");
	_balancingIsActive = false;
	_playerTeam = 0;
	
	ConVar insBotQuotaConVar = FindConVar("ins_bot_quota");
	PrintToServer("Changing ins_bot_quota from %d to %d.", insBotQuotaConVar.IntValue, _botQuota);
	insBotQuotaConVar.IntValue = _botQuota;
	
	ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
	PrintToServer("Changing mp_teams_unbalance_limit from %d to 1.", mpTeamsUnbalanceLimitConVar.IntValue);
	mpTeamsUnbalanceLimitConVar.IntValue = 1;
	
	int securityTeamPlayerCount = GetTeamClientCount(2);
	int insurgentsTeamPlayerCount = GetTeamClientCount(3);
	
	if (securityTeamPlayerCount > insurgentsTeamPlayerCount)
	{
		MoveXBotsFromTeamToTeam(2, 3, RoundToFloor(float((securityTeamPlayerCount - insurgentsTeamPlayerCount)) / float(2)));
	}
	else if (securityTeamPlayerCount < insurgentsTeamPlayerCount)
	{
		MoveXBotsFromTeamToTeam(3, 2, RoundToFloor(float((securityTeamPlayerCount - insurgentsTeamPlayerCount)) / float(2)));
	}
}

public int GetRealPlayerCount()
{
	int sum = 0;
	for (int i = 0; i < sizeof(_clientsRealPlayerStatus); i++)
	{
		if (_clientsRealPlayerStatus[i])
		{
			sum++;
		}
	}
	
	return sum;
}

public void KickXBotsFromTeam(int team, int botsToKick)
{
	int botsKicked = 0;
	for (int i = 1; i < MAXPLAYERS + 1; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == team)
		{
			KickClient(i);
			botsKicked++;
			if (botsKicked == botsToKick)
			{
				return;
			}
		}
	}
}

public void MoveXBotsFromTeamToTeam(int oldTeam, int newTeam, int botsToMove)
{
	int botsMoved = 0;
	for (int i = 1; i < MAXPLAYERS + 1; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == oldTeam)
		{
			ChangeClientTeam(i, newTeam);
			botsMoved++;
			if (botsMoved == botsToMove)
			{
				return;
			}
		}
	}
}
