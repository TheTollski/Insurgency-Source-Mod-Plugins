#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.03"

int _maxPlayersToEnableBotStacking = 3;

int _botsCurrentlyKickingFromTeam[4] = { 0, 0, 0, 0 };
bool _botStackingIsEnabled = false;
bool _clientsRealPlayerStatus[MAXPLAYERS + 1] = { false, ... };
int _desiredBotsOnRealPlayersTeam = 0;
int _desiredBotsOnOtherTeam = 0;
int _normalBotQuota = 0;
int _teamWithRealPlayers = 0;
bool _pluginIsChangingInsBotQuota = false;

public Plugin myinfo = 
{
	name = "Bot Stacker",
	author = "Tollski",
	description = "Stacks bots against players.",
	version = PLUGIN_VERSION,
	url = "Your website URL/AlliedModders profile URL"
};

// Forwards
public void OnPluginStart()
{
	CreateConVar("sm_botstacker_version", PLUGIN_VERSION, "Standard plugin version ConVar. Please don't change me!", FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	ConVar insBotQuotaConVar = FindConVar("ins_bot_quota");
	insBotQuotaConVar.AddChangeHook(ConVarChanged_InsBotQuota);

	HookEvent("player_team", Event_PlayerTeam);

	RegConsoleCmd("sm_testplayerjoiningsecurity", Command_TestPlayerJoiningSecurity, "Acts as if a player is joining Security.");
	RegConsoleCmd("sm_testplayerjoininginsurgents", Command_TestPlayerJoiningInsurgents, "Acts as if a player is joining Insurgents.");
	RegConsoleCmd("sm_testplayerleavingsecurity", Command_TestPlayerLeavingSecurity, "Acts as if a player is leaving Security.");
	RegConsoleCmd("sm_testplayerleavinginsurgents", Command_TestPlayerLeavingInsurgents, "Acts as if a player is leaving Insurgents.");
	// todo: OnClientConnect kick a bot if server is full
}

public void OnClientPutInServer(int client)
{	
	bool isRealPlayer = !IsFakeClient(client);
	_clientsRealPlayerStatus[client] = isRealPlayer;
	
	if (!isRealPlayer)
	{
		return;
	}
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(0, 0);
}

public void OnClientDisconnect(int client)
{
	bool wasRealPlayer = _clientsRealPlayerStatus[client];
	_clientsRealPlayerStatus[client] = false;
	
	if (!wasRealPlayer)
	{
		return;
	}
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(0, 0);
}

public void OnMapStart()
{

}

// Commands
public Action Command_TestPlayerJoiningSecurity(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[SM] Usage: sm_testplayerjoiningsecurity");
		return Plugin_Handled;
	}
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(0, 2);
	return Plugin_Handled;
}

public Action Command_TestPlayerJoiningInsurgents(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[SM] Usage: sm_testplayerjoininginsurgents");
		return Plugin_Handled;
	}
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(0, 3);
	return Plugin_Handled;
}

public Action Command_TestPlayerLeavingSecurity(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[SM] Usage: sm_testplayerleavingsecurity");
		return Plugin_Handled;
	}
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(2, 0);
	return Plugin_Handled;
}

public Action Command_TestPlayerLeavingInsurgents(int client, int args)
{
	if (args != 0) {
		ReplyToCommand(client, "[SM] Usage: sm_testplayerleavinginsurgents");
		return Plugin_Handled;
	}
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(3, 0);
	return Plugin_Handled;
}

// Hooks
public void ConVarChanged_InsBotQuota(ConVar convar, char[] oldValue, char[] newValue)
{
	//PrintToChatAll("%d, %d, %s, %s", _pluginIsChangingInsBotQuota, convar.IntValue, oldValue, newValue);
	if (!_botStackingIsEnabled || _pluginIsChangingInsBotQuota)
	{
		return;
	}

	ChangeBotQuota(StringToInt(oldValue), true);
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{	
	int userid = event.GetInt("userid");
	int team = event.GetInt("team");
	int oldteam = event.GetInt("oldteam");
	
	//PrintToChatAll("Player Team Event. userid: %d, team: %d, oldteam: %d.", userid, team, oldteam);

	int client = GetClientOfUserId(userid);
	bool isRealPlayer = !IsFakeClient(client);
	
	if (isRealPlayer)
	{
		CheckIfBotStackingStatusShouldBeEnabledAndSetIt(oldteam, team);
		
		return;
	}

	if (!_botStackingIsEnabled || team < 2)
	{
		return;
	}
	
	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteCell(team);
		
	CreateTimer(0.25, PlayerTeamEvent_Bot_AfterDelay, pack);
}

// 

public bool CheckIfBotStackingStatusShouldBeEnabledAndSetIt(int teamThatAPlayerIsLeaving, int teamThatAPlayerIsJoining)
{
	if (ShouldBotStackingBeEnabled(teamThatAPlayerIsLeaving, teamThatAPlayerIsJoining))
	{ 
		EnableBotStacking(teamThatAPlayerIsLeaving, teamThatAPlayerIsJoining);
	}
	else
	{
		DisableBotStacking();
	}
}

public bool ShouldBotStackingBeEnabled(int teamThatAPlayerIsLeaving, int teamThatAPlayerIsJoining)
{
	int realPlayerCount = GetRealPlayerCount();
	if (realPlayerCount > _maxPlayersToEnableBotStacking)
	{
		return false;
	}

	int realPlayersOnSecurityTeam = 0;
	int realPlayersOnInsurgentsTeam = 0;
	if (teamThatAPlayerIsJoining == 2) {
		realPlayersOnSecurityTeam++;
	}
	else if (teamThatAPlayerIsJoining == 3) {
		realPlayersOnInsurgentsTeam++;
	}

	if (teamThatAPlayerIsLeaving == 2) {
		realPlayersOnSecurityTeam--;
	}
	else if (teamThatAPlayerIsLeaving == 3) {
		realPlayersOnInsurgentsTeam--;
	}

	for (int i = 0; i < sizeof(_clientsRealPlayerStatus); i++)
	{
		if (_clientsRealPlayerStatus[i])
		{
			if (GetClientTeam(i) == 2)
			{
				realPlayersOnSecurityTeam++;
			}
			else if (GetClientTeam(i) == 3)
			{
				realPlayersOnInsurgentsTeam++;
			}
		}
	}

	//PrintToChatAll("Player joining team %d. There are %d human security and %d human insurgents.", teamThatAPlayerIsJoining, realPlayersOnSecurityTeam, realPlayersOnInsurgentsTeam);
	return (realPlayersOnInsurgentsTeam == 0 && realPlayersOnSecurityTeam > 0) || (realPlayersOnInsurgentsTeam > 0 && realPlayersOnSecurityTeam == 0);
}

public void EnableBotStacking(int teamThatAPlayerIsLeaving, int teamThatAPlayerIsJoining)
{
	if (!_botStackingIsEnabled)
	{
		PrintToServer("[Bot Stacker] EnableBotStacking");
		_botStackingIsEnabled = true;
		
		ChangeBotQuota(8, true); // todo: set quota based on max players
		
		ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
		PrintToServer("[Bot Stacker] Changing mp_teams_unbalance_limit from %d to 0.", mpTeamsUnbalanceLimitConVar.IntValue);
		mpTeamsUnbalanceLimitConVar.IntValue = 0;
	}

	int realPlayersOnSecurityTeam = 0;
	int realPlayersOnInsurgentsTeam = 0;
	if (teamThatAPlayerIsJoining == 2) {
		realPlayersOnSecurityTeam++;
	}
	else if (teamThatAPlayerIsJoining == 3) {
		realPlayersOnInsurgentsTeam++;
	}

	if (teamThatAPlayerIsLeaving == 2) {
		realPlayersOnSecurityTeam--;
	}
	else if (teamThatAPlayerIsLeaving == 3) {
		realPlayersOnInsurgentsTeam--;
	}

	for (int i = 0; i < sizeof(_clientsRealPlayerStatus); i++)
	{
		if (_clientsRealPlayerStatus[i])
		{
			if (GetClientTeam(i) == 2)
			{
				realPlayersOnSecurityTeam++;
			}
			else if (GetClientTeam(i) == 3)
			{
				realPlayersOnInsurgentsTeam++;
			}
		}
	}

	if (realPlayersOnSecurityTeam > 0 && realPlayersOnInsurgentsTeam > 0)
	{
		PrintToConsoleAll("[Bot Stacker] Trying to enable bot stacking but there seem to be real players on both teams.");
		DisableBotStacking();
		return;
	}

	int realPlayersOnTeam = 0;
	if (realPlayersOnSecurityTeam > 0)
	{
		_teamWithRealPlayers = 2;
		realPlayersOnTeam = realPlayersOnSecurityTeam;
	}
	else if (realPlayersOnInsurgentsTeam > 0)
	{
		_teamWithRealPlayers = 3;
		realPlayersOnTeam = realPlayersOnInsurgentsTeam;
	}
	else
	{
		PrintToConsoleAll("[Bot Stacker] Trying to enable bot stacking but there don't seem to be real players on either teams.");
		DisableBotStacking();
		return;
	}
	
	if (realPlayersOnTeam == 1)
	{
		_desiredBotsOnRealPlayersTeam = 1;
		_desiredBotsOnOtherTeam = 10;
	}
	else if (realPlayersOnTeam == 2)
	{
		_desiredBotsOnRealPlayersTeam = 0;
		_desiredBotsOnOtherTeam = 12;
	}
	else if (realPlayersOnTeam == 3)
	{
		_desiredBotsOnRealPlayersTeam = 0;
		_desiredBotsOnOtherTeam = 12;
	}
	else
	{
		PrintToChatAll("[Bot Stacker] Bot stacking not supported with %d real players on team.", realPlayersOnTeam);
	}

	SetBotsPerTeam(_teamWithRealPlayers == 2 ? _desiredBotsOnRealPlayersTeam : _desiredBotsOnOtherTeam, _teamWithRealPlayers == 3 ? _desiredBotsOnRealPlayersTeam : _desiredBotsOnOtherTeam);
}

public void DisableBotStacking()
{
	if (!_botStackingIsEnabled)
	{
		return;
	}
	
	PrintToServer("[Bot Stacker] DisableBotStacking");
	_botStackingIsEnabled = false;
	_desiredBotsOnRealPlayersTeam = 0;
	_desiredBotsOnOtherTeam = 0;
	_teamWithRealPlayers = 0;
	
	ChangeBotQuota(_normalBotQuota, false);
	
	ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
	PrintToServer("[Bot Stacker] Changing mp_teams_unbalance_limit from %d to 1.", mpTeamsUnbalanceLimitConVar.IntValue);
	mpTeamsUnbalanceLimitConVar.IntValue = 1;

	int securityTeamPlayerCount = GetTeamClientCount(2);
	int insurgentsTeamPlayerCount = GetTeamClientCount(3);
	
	if (securityTeamPlayerCount > insurgentsTeamPlayerCount)
	{
		MoveXBotsFromTeamToTeam(2, 3, RoundToCeil(float((securityTeamPlayerCount - insurgentsTeamPlayerCount)) / float(2)));
	}
	else if (securityTeamPlayerCount < insurgentsTeamPlayerCount)
	{
		MoveXBotsFromTeamToTeam(3, 2, RoundToCeil(float((insurgentsTeamPlayerCount - securityTeamPlayerCount)) / float(2)));
	}
}

// Helper Functions

public void ChangeBotQuota(int newQuota, bool savePreviousQuota)
{
	ConVar insBotQuotaConVar = FindConVar("ins_bot_quota");
	PrintToServer("[Bot Stacker] Changing ins_bot_quota from %d to %d.", insBotQuotaConVar.IntValue, newQuota);

	if (savePreviousQuota)
	{
		_normalBotQuota = insBotQuotaConVar.IntValue;
	}

	_pluginIsChangingInsBotQuota = true;
	insBotQuotaConVar.IntValue = newQuota;
	_pluginIsChangingInsBotQuota = false;
}

public Action DecrementBotsCurrentlyKicking_AfterDelay(Handle timer, int team)
{
	_botsCurrentlyKickingFromTeam[team]--;
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
	//PrintToChatAll("KickXBotsFromTeam: %d, %d", team, botsToKick);
	int botsKicked = 0;
	for (int i = 1; i < MaxClients + 1; i++)
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
	//PrintToChatAll("MoveXBotsFromTeamToTeam: %d, %d, %d", oldTeam, newTeam, botsToMove);
	int botsMoved = 0;
	for (int i = 1; i < MaxClients + 1; i++)
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

public Action PlayerTeamEvent_Bot_AfterDelay(Handle timer, DataPack inputPack)
{
	inputPack.Reset();
	int client = inputPack.ReadCell();
	int team = inputPack.ReadCell();
	CloseHandle(inputPack);

	int currentBotsOnSecurity = 0;
	int currentBotsOnInsurgents = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i))
		{
			int t = GetClientTeam(i);
			if(t == 2)
			{
				currentBotsOnSecurity++;
			}
			else if (t == 3)
			{
				currentBotsOnInsurgents++;
			}
		}
	}

	int botsOnThisTeam = team == 2 ? currentBotsOnSecurity : currentBotsOnInsurgents;
	int botsOnOtherTeam = team == 2 ? currentBotsOnInsurgents : currentBotsOnSecurity;
	int desiredBotsOnThisTeam = team == _teamWithRealPlayers ? _desiredBotsOnRealPlayersTeam : _desiredBotsOnOtherTeam;
	int desiredBotsOnOtherTeam = team == _teamWithRealPlayers ? _desiredBotsOnOtherTeam : _desiredBotsOnRealPlayersTeam;

	int otherTeam = team == 2 ? 3 : 2;
	//PrintToChatAll("botsThisTeam: %d/%d, botsOtherTeam: %d/%d, kicking: %d", botsOnThisTeam, desiredBotsOnThisTeam, botsOnOtherTeam, desiredBotsOnOtherTeam, _botsCurrentlyKickingFromTeam[team]);

	if (botsOnThisTeam - _botsCurrentlyKickingFromTeam[team] <= desiredBotsOnThisTeam)
	{
		return;
	}
	
	if (botsOnOtherTeam < desiredBotsOnOtherTeam)
	{
		//PrintToChatAll("Moving this bot.");
		ChangeClientTeam(client, otherTeam);
		return;
	}

	//PrintToChatAll("Kicking this bot.");
	_botsCurrentlyKickingFromTeam[team]++;
	KickClient(client);
	CreateTimer(0.1, DecrementBotsCurrentlyKicking_AfterDelay, team);
}

public void SetBotsPerTeam(int botsOnSecurity, int botsOnInsurgents)
{
	//PrintToChatAll("SetBotsPerTeam: %d, %d", botsOnSecurity, botsOnInsurgents);
	int currentBotsOnSecurity = 0;
	int currentBotsOnInsurgents = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i))
		{
			int team = GetClientTeam(i);
			if(team == 2)
			{
				currentBotsOnSecurity++;
			}
			else if (team == 3)
			{
				currentBotsOnInsurgents++;
			}
		}
	}

	//PrintToChatAll("currentBots: %d, %d", currentBotsOnSecurity, currentBotsOnInsurgents);

	if (botsOnSecurity < currentBotsOnSecurity)
	{
		if (botsOnInsurgents > currentBotsOnInsurgents)
		{
			int botsNeededOtherTeam = botsOnInsurgents - currentBotsOnInsurgents;
			int botSurplusThisTeam = currentBotsOnSecurity - botsOnSecurity;
			int botsToMove = botSurplusThisTeam > botsNeededOtherTeam ? botsNeededOtherTeam : botSurplusThisTeam;
			MoveXBotsFromTeamToTeam(2, 3, botsToMove);
			currentBotsOnSecurity -= botsToMove;
			currentBotsOnInsurgents += botsToMove;
		}

		if (botsOnSecurity < currentBotsOnSecurity)
		{
			KickXBotsFromTeam(2, currentBotsOnSecurity - botsOnSecurity);
		}
	}
	if (botsOnInsurgents < currentBotsOnInsurgents)
	{
		if (botsOnSecurity > currentBotsOnSecurity)
		{
			int botsNeededOtherTeam = botsOnSecurity - currentBotsOnSecurity;
			int botSurplusThisTeam = currentBotsOnInsurgents - botsOnInsurgents;
			int botsToMove = botSurplusThisTeam > botsNeededOtherTeam ? botsNeededOtherTeam : botSurplusThisTeam;
			MoveXBotsFromTeamToTeam(3, 2, botsToMove);
			currentBotsOnSecurity += botsToMove;
			currentBotsOnInsurgents -= botsToMove;
		}

		if (botsOnInsurgents < currentBotsOnInsurgents)
		{
			KickXBotsFromTeam(3, currentBotsOnInsurgents - botsOnInsurgents);
		}
	}
}
