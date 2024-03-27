#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.07"

int _maxPlayersToEnableBotStacking = 3;

int _botsCurrentlyKickingFromTeam[4] = { 0, 0, 0, 0 };
bool _botStackingIsEnabled = false;
bool _clientsRealPlayerStatus[MAXPLAYERS + 1] = { false, ... };
int _desiredBotsOnRealPlayersTeam = 0;
int _desiredBotsOnOtherTeam = 0;
int _normalBotQuota = 0;
int _normalTeamsUnbalanceLimit = 0;
int _teamWithRealPlayers = 0;
bool _pluginIsChangingInsBotQuota = false;

ConVar _cvarShufflePlayersAfterStackingDisabled = null;

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
	HookEvent("round_end", Event_RoundEnd);

	RegConsoleCmd("sm_setbotcounts", Command_SetBotCounts, "Sets desired bot counts for each team.");
	RegConsoleCmd("sm_testplayerjoiningteam", Command_TestPlayerJoiningTeam, "Acts as if a real player is joining team.");
	RegConsoleCmd("sm_testplayerleavingteam", Command_TestPlayerLeavingTeam, "Acts as if a real player is leaving team.");

	_cvarShufflePlayersAfterStackingDisabled = CreateConVar("sm_botstacker_shuffle_players", "1", "Shuffle players to balance teams after stacking disabled?");
	AutoExecConfig(true, "botstacker");
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	int clientCount = GetClientCount(false);
	bool isFakeClient = IsFakeClient(client);

	//PrintToChatAll("OnClientConnect. clientCount: %d, MaxClients: %d, isFakeClient: %d.", clientCount, MaxClients, isFakeClient);
	if (clientCount == MaxClients && !isFakeClient)
	{
		for (int i = 1; i < MaxClients + 1; i++)
		{
			if (IsClientInGame(i) && IsFakeClient(i))
			{
				PrintToServer("[Bot Stacker] A human is trying to connect to fill the last open slot on the server. Kicking a random bot to keep an open slot on the server.");
				KickClient(i);
				return true;
			}
		}
	}

	return true;
}

public void OnClientConnected(int client)
{
	int clientCount = GetClientCount(false);
	bool isFakeClient = IsFakeClient(client);

	//PrintToChatAll("OnClientConnected. clientCount: %d, MaxClients: %d, isFakeClient: %d.", clientCount, MaxClients, isFakeClient);
	if (clientCount == MaxClients && isFakeClient)
	{
		PrintToServer("[Bot Stacker] A bot connected and filled the last open slot on the server. Kicking bot.");
		KickClient(client);	
	}
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

public Action Command_SetBotCounts(int client, int args)
{
	if (args != 2) {
		ReplyToCommand(client, "[Bot Stacker] Usage: sm_setbotcounts <desiredAlliedBotCount> <desiredEnemyBotCount>");
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	int desiredBotsOnRealPlayersTeam = StringToInt(arg1);

	char arg2[32];
	GetCmdArg(2, arg2, sizeof(arg2));
	int desiredBotsOnOtherTeam = StringToInt(arg2);
	
	if (!_botStackingIsEnabled)
	{
		ReplyToCommand(client, "[Bot Stacker] Failed to set bot counts; bot stacking is not currently enabled.");
		return Plugin_Handled;
	}

	int realPlayersOnTeam = 0;
	for (int i = 0; i < sizeof(_clientsRealPlayerStatus); i++)
	{
		if (_clientsRealPlayerStatus[i] && GetClientTeam(i) == _teamWithRealPlayers)
		{
			realPlayersOnTeam++;
		}
	}

	if (realPlayersOnTeam > 1)
	{
		ReplyToCommand(client, "[Bot Stacker] Failed to set bot counts; you aren't the only player on your team.");
		return Plugin_Handled;
	}

	int maxBotsCurrentlyAllowed = MaxClients - realPlayersOnTeam - 2;
	if (desiredBotsOnRealPlayersTeam + desiredBotsOnOtherTeam > maxBotsCurrentlyAllowed)
	{
		ReplyToCommand(client, "[Bot Stacker] Failed to set bot counts; selected bot counts are too high. Max bots you can currently add is %d.", maxBotsCurrentlyAllowed);
		return Plugin_Handled;
	}

	_desiredBotsOnRealPlayersTeam = desiredBotsOnRealPlayersTeam;
	_desiredBotsOnOtherTeam = desiredBotsOnOtherTeam;
	SetBotsPerTeam(_teamWithRealPlayers == 2 ? _desiredBotsOnRealPlayersTeam : _desiredBotsOnOtherTeam, _teamWithRealPlayers == 3 ? _desiredBotsOnRealPlayersTeam : _desiredBotsOnOtherTeam);
	ReplyToCommand(client, "[Bot Stacker] Allied bot count set to %d. Enemy bot count set to %d.", _desiredBotsOnRealPlayersTeam, _desiredBotsOnOtherTeam);
	return Plugin_Handled;
}

public Action Command_TestPlayerJoiningTeam(int client, int args)
{
	if (args != 1) {
		ReplyToCommand(client, "[Bot Stacker] Usage: sm_testplayerjoiningteam <team#>");
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	int team = StringToInt(arg1);
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(0, team);
	return Plugin_Handled;
}

public Action Command_TestPlayerLeavingTeam(int client, int args)
{
	if (args != 1) {
		ReplyToCommand(client, "[Bot Stacker] Usage: sm_testplayerleavingteam <team#>");
		return Plugin_Handled;
	}

	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	int team = StringToInt(arg1);
	
	CheckIfBotStackingStatusShouldBeEnabledAndSetIt(team, 0);
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

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	// If there are too many bots on one team the game won't add enough bots to the other team to stack teams as desired.
	ConVar insBotQuotaConVar = FindConVar("ins_bot_quota");
	int currentBotQuota = insBotQuotaConVar.IntValue;

	int currentBotsOnSecurity = 0;
	int currentBotsOnInsurgents = 0;
	for (int i = 1; i < MaxClients + 1; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i))
		{
			int t = GetClientTeam(i);
			if(t == 2)
			{
				if (currentBotsOnSecurity >= currentBotQuota)
				{
					KickClient(i);
					continue;
				}
				
				currentBotsOnSecurity++;
			}
			else if (t == 3)
			{
				if (currentBotsOnInsurgents >= currentBotQuota)
				{
					KickClient(i);
					continue;
				}

				currentBotsOnInsurgents++;
			}
		}
	}
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
		DisableBotStacking(teamThatAPlayerIsLeaving, teamThatAPlayerIsJoining);
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
		PrintToChatAll("[Bot Stacker] All players are on one team: enabling bot stacking.");
		_botStackingIsEnabled = true;
		
		ChangeBotQuota(RoundToFloor(float(MaxClients) / float(2)) - 1, true);
		
		ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
		PrintToServer("[Bot Stacker] Changing mp_teams_unbalance_limit from %d to 0.", mpTeamsUnbalanceLimitConVar.IntValue);
		_normalTeamsUnbalanceLimit = mpTeamsUnbalanceLimitConVar.IntValue;
		int mpTeamsUnbalanceLimitConVarFlags = mpTeamsUnbalanceLimitConVar.Flags;
		mpTeamsUnbalanceLimitConVar.Flags = 0;
		mpTeamsUnbalanceLimitConVar.IntValue = 0;
		mpTeamsUnbalanceLimitConVar.Flags = mpTeamsUnbalanceLimitConVarFlags;
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
		DisableBotStacking(teamThatAPlayerIsLeaving, teamThatAPlayerIsJoining);
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
		DisableBotStacking(teamThatAPlayerIsLeaving, teamThatAPlayerIsJoining);
		return;
	}
	
	if (realPlayersOnTeam == 1)
	{
		_desiredBotsOnRealPlayersTeam = 1;
		_desiredBotsOnOtherTeam = 8;
	}
	else if (realPlayersOnTeam == 2)
	{
		_desiredBotsOnRealPlayersTeam = 0;
		_desiredBotsOnOtherTeam = 9;
	}
	else if (realPlayersOnTeam == 3)
	{
		_desiredBotsOnRealPlayersTeam = 0;
		_desiredBotsOnOtherTeam = 11;
	}
	else
	{
		PrintToConsoleAll("[Bot Stacker] Bot stacking not supported with %d real players on team.", realPlayersOnTeam);
		DisableBotStacking(teamThatAPlayerIsLeaving, teamThatAPlayerIsJoining);
		return;
	}

	int maxBotsCurrentlyAllowed = MaxClients - realPlayersOnTeam - 2;
	if (_desiredBotsOnRealPlayersTeam + _desiredBotsOnOtherTeam > maxBotsCurrentlyAllowed)
	{
		_desiredBotsOnOtherTeam = maxBotsCurrentlyAllowed - _desiredBotsOnRealPlayersTeam;
	}

	SetBotsPerTeam(_teamWithRealPlayers == 2 ? _desiredBotsOnRealPlayersTeam : _desiredBotsOnOtherTeam, _teamWithRealPlayers == 3 ? _desiredBotsOnRealPlayersTeam : _desiredBotsOnOtherTeam);
	
	if (realPlayersOnTeam == 1)
	{
		PrintToChatAll("[Bot Stacker] Allied bot count set to %d, enemy bot count set to %d. In single player mode you can set bot counts by typing: !setbotcounts <desiredAlliedBotCount> <desiredEnemyBotCount> (eg. '!setbotcounts 0 13').", _desiredBotsOnRealPlayersTeam, _desiredBotsOnOtherTeam);
	}
	else
	{
		PrintToChatAll("[Bot Stacker] Allied bot count set to %d, enemy bot count set to %d.", _desiredBotsOnRealPlayersTeam, _desiredBotsOnOtherTeam);
	}
}

public void DisableBotStacking(int teamThatAPlayerIsLeaving, int teamThatAPlayerIsJoining)
{
	if (!_botStackingIsEnabled)
	{
		return;
	}
	
	PrintToServer("[Bot Stacker] DisableBotStacking");
	PrintToChatAll("[Bot Stacker] More than %d players are in the server or players are on different teams: disabling bot stacking.", _maxPlayersToEnableBotStacking);
	_botStackingIsEnabled = false;
	_desiredBotsOnRealPlayersTeam = 0;
	_desiredBotsOnOtherTeam = 0;
	_teamWithRealPlayers = 0;
	
	ChangeBotQuota(_normalBotQuota, false);
	
	ConVar mpTeamsUnbalanceLimitConVar = FindConVar("mp_teams_unbalance_limit");
	PrintToServer("[Bot Stacker] Changing mp_teams_unbalance_limit from %d to %d.", mpTeamsUnbalanceLimitConVar.IntValue, _normalTeamsUnbalanceLimit);
	int mpTeamsUnbalanceLimitConVarFlags = mpTeamsUnbalanceLimitConVar.Flags;
	mpTeamsUnbalanceLimitConVar.Flags = 0;
	mpTeamsUnbalanceLimitConVar.IntValue = _normalTeamsUnbalanceLimit;
	mpTeamsUnbalanceLimitConVar.Flags = mpTeamsUnbalanceLimitConVarFlags;

	int realPlayerChangeSecurity = 0;
	int realPlayerChangeInsurgents = 0;
	if (teamThatAPlayerIsJoining == 2) {
		realPlayerChangeSecurity++;
	}
	else if (teamThatAPlayerIsJoining == 3) {
		realPlayerChangeInsurgents++;
	}

	if (teamThatAPlayerIsLeaving == 2) {
		realPlayerChangeSecurity--;
	}
	else if (teamThatAPlayerIsLeaving == 3) {
		realPlayerChangeInsurgents--;
	}

	if (_cvarShufflePlayersAfterStackingDisabled.BoolValue)
	{
		int realPlayersOnSecurityTeam = realPlayerChangeSecurity;
		int realPlayersOnInsurgentsTeam = realPlayerChangeInsurgents;

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

		int realPlayerDifference = realPlayersOnSecurityTeam - realPlayersOnInsurgentsTeam;
		realPlayerDifference = realPlayerDifference < 0 ? -realPlayerDifference : realPlayerDifference;
		int realPlayersToMove = RoundToFloor(float((realPlayerDifference)) / float(2));
		if (realPlayersOnSecurityTeam > realPlayersOnInsurgentsTeam)
		{
			realPlayerChangeSecurity -= realPlayersToMove;
			realPlayerChangeInsurgents += realPlayersToMove;
			MoveXPlayersFromTeamToTeam(2, 3, realPlayersToMove);
		}
		else if (realPlayersOnSecurityTeam < realPlayersOnInsurgentsTeam)
		{
			realPlayerChangeSecurity += realPlayersToMove;
			realPlayerChangeInsurgents -= realPlayersToMove;
			MoveXBotsFromTeamToTeam(3, 2, realPlayersToMove);
		}
	}

	int securityTeamPlayerCount = GetTeamClientCount(2) + realPlayerChangeSecurity;
	int insurgentsTeamPlayerCount = GetTeamClientCount(3) + realPlayerChangeInsurgents;
	
	int playerDifference = securityTeamPlayerCount - insurgentsTeamPlayerCount;
	playerDifference = playerDifference < 0 ? -playerDifference : playerDifference;
	int botsToMove = RoundToCeil(float((playerDifference)) / float(2));
	if (securityTeamPlayerCount > insurgentsTeamPlayerCount)
	{
		MoveXBotsFromTeamToTeam(2, 3, botsToMove);
	}
	else if (securityTeamPlayerCount < insurgentsTeamPlayerCount)
	{
		MoveXBotsFromTeamToTeam(3, 2, botsToMove);
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
	if (botsToKick == 0)
	{
		return;
	}

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

	if (botsToMove == 0)
	{
		return;
	}

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

public void MoveXPlayersFromTeamToTeam(int oldTeam, int newTeam, int playersToMove)
{
	//PrintToChatAll("MoveXPlayersFromTeamToTeam: %d, %d, %d", oldTeam, newTeam, playersToMove);
	if (playersToMove == 0)
	{
		return;
	}

	int playersMoved = 0;
	for (int i = MaxClients; i >= 0; i--)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == oldTeam)
		{
			ChangeClientTeam(i, newTeam);
			PrintToChat(i, "[Bot Stacker] You have been moved to the other team.");
			playersMoved++;
			if (playersMoved == playersToMove)
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
