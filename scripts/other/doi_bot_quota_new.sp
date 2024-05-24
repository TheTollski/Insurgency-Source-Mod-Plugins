#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

ConVar convar_Quota;
ConVar convar_DOI_Quota;

public Plugin myinfo = {
	name = "[DOI] Bot-Quota", 
	author = "Drixevel, Lua (Edited by Tollski)", 
	description = "Manually enforces a bot quota.", 
	version = "1.1.1", 
	url = "https://drixevel.dev/"
};

public void OnPluginStart() {
	convar_Quota = CreateConVar("sm_bot_quota", "0", "Bot Quota Hax", FCVAR_PROTECTED);
	convar_Quota.AddChangeHook(ConVarChanged_SmBotQuota);
	convar_DOI_Quota = FindConVar("doi_bot_quota");

	RegAdminCmd("removebots", cmd_removebots, ADMFLAG_RESERVATION, "remove all bots");

	CreateTimer(2.0, Timer_BotUpdate, _, TIMER_REPEAT);
}

public void OnConfigsExecuted() {
	if (convar_Quota.IntValue > 0) {
		SetConVarBounds(convar_DOI_Quota, ConVarBound_Lower, true, convar_Quota.FloatValue);
		SetConVarBounds(convar_DOI_Quota, ConVarBound_Upper, true, convar_Quota.FloatValue);
		convar_DOI_Quota.IntValue = convar_Quota.IntValue;
	}
}

public Action cmd_removebots(int client, int args) {
	ServerCommand("sm_bot_quota 0");
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || !IsFakeClient(i) || GetClientTeam(i) < 2) {
			continue;
		}
		KickClient(i);
	}

	ReplyToCommand(client, "Done");
	return Plugin_Handled;
}

public void ConVarChanged_SmBotQuota(ConVar convar, char[] oldValue, char[] newValue)
{
	SetConVarBounds(convar_DOI_Quota, ConVarBound_Lower, true, convar_Quota.FloatValue);
	SetConVarBounds(convar_DOI_Quota, ConVarBound_Upper, true, convar_Quota.FloatValue);
	convar_DOI_Quota.IntValue = convar_Quota.IntValue;
	PrintToConsoleAll("New bot quota: %d", convar_DOI_Quota.IntValue);
}

public Action Timer_BotUpdate(Handle timer) {
	int botQuota = convar_DOI_Quota.IntValue;
	if (botQuota > 0) {
		int teamOneBots = 0;
		int teamTwoBots = 0;
		int teamOnePlayers = 0;
		int teamTwoPlayers = 0;

		for (int i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i)) {
				int team = GetClientTeam(i);
				bool isBot = IsFakeClient(i);
				if (team == 2) {
					if (!isBot) teamOnePlayers++;
					else teamOneBots++;
				}
				else if (team == 3) {
					if (!isBot) teamTwoPlayers++;
					else teamTwoBots++;
				}
			} else if (IsClientConnected(i) && !IsFakeClient(i)) {
				botQuota--;
			}
		}

		int teamOneTotal = teamOneBots+teamOnePlayers;
		int teamTwoTotal = teamTwoBots+teamTwoPlayers;
		if (teamOneTotal < botQuota) {
			ServerCommand("doi_bot_add %d 2", botQuota-teamOneTotal);
		} else if (teamOneTotal > botQuota) {
			ServerCommand("ins_bot_kick %d 2", teamOneTotal-botQuota);
		}

		if (teamTwoTotal < botQuota) {
			ServerCommand("doi_bot_add %d 3", botQuota-teamTwoTotal);
		} else if (teamTwoTotal > botQuota) {
			ServerCommand("ins_bot_kick %d 3", teamTwoTotal-botQuota);
		}
	}
}