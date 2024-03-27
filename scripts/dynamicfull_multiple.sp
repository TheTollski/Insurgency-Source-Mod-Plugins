#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

char strPrefix[64] = "\x01\x03[\x04Dynamic\x03]\x01";

ConVar global_playercount[3][2];
ConVar global_mapcycle[3];
ConVar global_playlist[3];
ConVar global_playtext[3];
ConVar global_bot;
ConVar global_log;
char gNextLevel[128];

// A boolean that checks if medium is allowed
// Disabled by default.
// How it works:
// IF we have a full server / game, it then activates (only checks on game_end event)
// and if our player count goes down to default, then disable it.
bool global_EnableMediumCycle = false;

// Since medium and high use the same playlist, custom, it cannot use the changelevel
// when switching betwen the two. So to fix that, this little workaround will do the trick.
// Only triggered if index it higher than 0
int global_IndexRemember = 0;

public Plugin myinfo = {
	name = "Dynamic MapScale & Playlist",
	author = "Nades, updated and modified by JonnyBoy0719, Linothorax, and Tollski",
	description = "Dynamically update the mapcycle and playlist.",
	version = "0.12",
	url = ""
}

public void OnPluginStart() {
	global_playercount[0][0] = CreateConVar("sm_playercount_default_min", "0", "Number of min players needed to switch on Playlist #1", _, true, 0.0, false, 128.0);
	global_playercount[0][1] = CreateConVar("sm_playercount_default_max", "10", "Number of max players needed to switch on Playlist #1", _, true, 0.0, false, 128.0);

	global_playercount[1][0] = CreateConVar("sm_playercount_medium_min", "11", "Number of min players needed to switch on Playlist #2", _, true, 0.0, false, 128.0);
	global_playercount[1][1] = CreateConVar("sm_playercount_medium_max", "20", "Number of max players needed to switch on Playlist #2", _, true, 0.0, false, 128.0);

	global_playercount[2][0] = CreateConVar("sm_playercount_high_min", "21", "Number of min players needed to switch on Playlist #3", _, true, 0.0, false, 128.0);
	global_playercount[2][1] = CreateConVar("sm_playercount_high_max", "49", "Number of max players needed to switch on Playlist #3", _, true, 0.0, false, 128.0);

	global_mapcycle[0] = CreateConVar("sm_mapcycle_default", "mapcycle_launch.txt", "Mapcycle to load for #1");
	global_mapcycle[1] = CreateConVar("sm_mapcycle_medium", "mapcycle_default.txt", "Mapcycle to load for #2");
	global_mapcycle[2] = CreateConVar("sm_mapcycle_high", "mapcycle_custom.txt", "Mapcycle to load for #3");

	global_playlist[0] = CreateConVar("sm_playlist_default", "nwi/pvp_sustained", "Playlist to load for #1");
	global_playlist[1] = CreateConVar("sm_playlist_medium", "nwi/pvp_sustained", "Playlist to load for #2");
	global_playlist[2] = CreateConVar("sm_playlist_high", "nwi/pvp_sustained", "Playlist to load for #3");

	global_playtext[0] = CreateConVar("sm_playtext_default", "Official", "Text for #1");
	global_playtext[1] = CreateConVar("sm_playtext_medium", "Medium", "Text for #2");
	global_playtext[2] = CreateConVar("sm_playtext_high", "High", "Text for #3");

	global_bot = CreateConVar("sm_playercount_bot", "0", "Debug: Counting bot as players");
	global_log = CreateConVar("sm_mapcycle_log", "0", "Debug: Logging plugin");

	HookEvent("game_end", Event_GameEnd_Pre, EventHookMode_Pre);
	RegAdminCmd("sm_endround", Command_EndRound, ADMFLAG_ROOT, "sm_endround");
}

public Action Command_EndRound(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_endround <team>");
		return Plugin_Handled;
	}
	
	int iLogicEnt;
	iLogicEnt = FindEntityByClassname(-1, "ins_rulesproxy");

	if (iLogicEnt > MaxClients && IsValidEntity(iLogicEnt))
	{
		char cArg[255];
		GetCmdArg(1, cArg, sizeof(cArg));
		SetVariantInt(StringToInt(cArg));
		AcceptEntityInput(iLogicEnt, "EndRound");
		PrintToChatAll("\x04Round Ended by Admin");
	} else {
		ReplyToCommand(client, "[SM] Couldn't find rulesproxy logic entity, need to fix :(");
	}
	return Plugin_Handled;
}

public Action Event_GameEnd_Pre(Handle event, const char[] name, bool dontBroadcast) {
	hasEnoughPlayer();
}

void hasEnoughPlayer() {
	int intPlayerCount = 0;
	for (int client = 1;client <= MaxClients;client++) {
		if (!IsClientInGame(client)) continue;
		if (global_bot.BoolValue == false && (IsFakeClient(client) || IsClientSourceTV(client))) continue;

		intPlayerCount++;
	}
	char strMapcycle[64], strPlaylist[64], strConvarMap[64], strConvarPlay[64], strPlayText[255];
	bool _log = global_log.BoolValue;

	GetConVarString(FindConVar("mapcyclefile"), strConvarMap, sizeof(strConvarMap));
	GetConVarString(FindConVar("sv_playlist"), strConvarPlay, sizeof(strConvarPlay));

	int index = -1;
	for (int i = 0; i < 3; i++) {
		if (intPlayerCount >= global_playercount[i][0].IntValue && intPlayerCount <= global_playercount[i][1].IntValue) {
			index = i;
			break;
		}
	}

	if (_log) LogMessage("[Dynamic] Game ended with %d players (index: %d, EnableMediumCycle: %d)", intPlayerCount, index, global_EnableMediumCycle);

	if ( !global_EnableMediumCycle && index == 1 )
	{
		// Reset to 0, since medium cycle is disabled.
		index = 0;
		if (_log) LogMessage("[Dynamic] EnableMediumCycle disabled, changing index to 0 (default)");
	}

	if (index == -1) {
		if (_log) LogMessage("[Dynamic] No matching mapcycle, plugin skipping...");
		return;
	}

	global_mapcycle[index].GetString(strMapcycle, sizeof(strMapcycle));
	global_playlist[index].GetString(strPlaylist, sizeof(strPlaylist));
	global_playtext[index].GetString(strPlayText, sizeof(strPlayText));
	if (_log) {
		LogMessage("[Dynamic] Current Mapcycle: \"%s\", Playlist: \"%s\"", strConvarMap, strConvarPlay);
		LogMessage("[Dynamic] Selected Mapcycle: \"%s\", Playlist: \"%s\", PlayText: \"%s\"", strMapcycle, strPlaylist, strPlayText);
	}

	if (StrEqual(strConvarMap, strMapcycle) && StrEqual(strConvarPlay, strPlaylist)) {
		return;
	}

	if (!StrEqual(strConvarMap, strMapcycle)) {
		if (_log) LogMessage("[Dynamic] Changing mapcycle from '%s' to '%s'...", strConvarMap, strMapcycle);
		PrintToChatAll("%s Changing mapcycle from '%s' to '%s'...", strPrefix, strConvarMap, strMapcycle);
		ServerCommand("mapcyclefile %s", strMapcycle);
	}
	if (!StrEqual(strConvarPlay, strPlaylist)) {
		if (_log) LogMessage("[Dynamic] Changing playlist from '%s' to '%s'...", strConvarPlay, strPlaylist);
		PrintToChatAll("%s Changing playlist from '%s' to '%s'...", strPrefix, strConvarPlay, strPlaylist);
		ServerCommand("sv_playlist %s", strPlaylist);
	}

	gNextLevel = "";
	switch(index)
	{
		case 0:
		{
			// #1 Default
			global_EnableMediumCycle = false;
			switch(GetRandomInt(0, 15))
			{
				case 0: gNextLevel = "buhriz push";
				case 1: gNextLevel = "contact push";
				case 2: gNextLevel = "district push";
				case 3: gNextLevel = "drycanal push";
				case 4: gNextLevel = "embassy push";
				case 5: gNextLevel = "heights push";
				case 6: gNextLevel = "kandagal push";
				case 7: gNextLevel = "market push";
				case 8: gNextLevel = "panj push";
				case 9: gNextLevel = "peak push";
				case 10: gNextLevel = "revolt push";
				case 11: gNextLevel = "siege push";
				case 12: gNextLevel = "sinjar push";
				case 13: gNextLevel = "station push";
				case 14: gNextLevel = "tell push";
				case 15: gNextLevel = "verticality push";
			}
		}
		case 1:
		{
			// #2 Medium
			switch(GetRandomInt(0, 16))
			{
				case 0: gNextLevel = "favela_k_fix occupy";
				case 1: gNextLevel = "dgl_street3 firefight";
				case 2: gNextLevel = "3mc_training_p1fix firefight";
				case 3: gNextLevel = "ins_awp_metro_p1 firefight";
				case 4: gNextLevel = "point_blank_fix occupy";
				case 5: gNextLevel = "de_lake occupy";
				case 6: gNextLevel = "tc_bridgecrossing_night occupy";
				case 7: gNextLevel = "killhouse occupy";
				case 8: gNextLevel = "dgl_snipe4 firefight";
				case 9: gNextLevel = "ins_aim_dark_water_p2 firefight";
				case 10: gNextLevel = "pine_village_v4 occupy";
				case 11: gNextLevel = "reef_koth occupy";
				case 12: gNextLevel = "italy_b1_k_fix skirmish";
				case 13: gNextLevel = "strawberry_arena_koth occupy";
				case 14: gNextLevel = "nightstalker_v2 skirmish";
				case 15: gNextLevel = "dgl_paintball4_d occupy";
				case 16: gNextLevel = "ins_abdallah_b3 push";
			}
		}
		case 2:
		{
			// #3 High
			global_EnableMediumCycle = true;
			switch(GetRandomInt(0, 18))
			{
				case 0: gNextLevel = "buhriz push";
				case 1: gNextLevel = "contact push";
				case 2: gNextLevel = "district push";
				case 3: gNextLevel = "drycanal push";
				case 4: gNextLevel = "embassy push";
				case 5: gNextLevel = "heights push";
				case 6: gNextLevel = "kandagal push";
				case 7: gNextLevel = "market push";
				case 8: gNextLevel = "panj push";
				case 9: gNextLevel = "peak push";
				case 10: gNextLevel = "revolt push";
				case 11: gNextLevel = "siege push";
				case 12: gNextLevel = "sinjar push";
				case 13: gNextLevel = "station push";
				case 14: gNextLevel = "tell push";
				case 15: gNextLevel = "verticality push";
				case 16: gNextLevel = "baghdad_pvp push";
				case 17: gNextLevel = "baghdad_b5 push";
				case 18: gNextLevel = "almaden_b5 push";
			}
		}
	}

	if (_log) LogMessage("[Dynamic] Setting the Index Remember from %d to %d)", index, global_IndexRemember);
	global_IndexRemember = index;
	CreateTimer(5.0, Timer_Changelevel, _, TIMER_FLAG_NO_MAPCHANGE);
	if (_log) LogMessage("[Dynamic] Selected next map from \"%s\" map list is \"%s\"", strPlayText, gNextLevel);
}

public Action Timer_Changelevel(Handle timer) {
	if (global_log.BoolValue) LogMessage("[Dynamic] Changelevel to \"%s\"", gNextLevel);
	ServerCommand("changelevel %s", gNextLevel);
}
