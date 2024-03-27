//(C) 2020 rrrfffrrr <rrrfffrrr@naver.com>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {
	name		= "[INS] Fire support",
	author		= "rrrfffrrr & modified by JonnyBoy0719",
	description	= "Fire support",
	version		= "1.1.3",
	url			= ""
};

#include <sourcemod>
#include <datapack>
#include <float>
#include <sdktools>
#include <sdktools_trace>
#include <sdktools_functions>
#include <timers>

const int TEAM_SPECTATE = 1;
const int TEAM_SECURITY = 2;
const int TEAM_INSURGENT = 3;

const float MATH_PI = 3.14159265359;

float UP_VECTOR[3] = {-90.0, 0.0, 0.0};
float DOWN_VECTOR[3] = {90.0, 0.0, 0.0};

Handle cGameConfig;
Handle fCreateRocket;
// Need signature below
//"CBaseRocketMissile::CreateRocketMissile"
//{
//	"library"	"server"
//	"windows"	"\x55\x8B\xEC\x83\xEC\x28\x53\x8B\x5D\x08"
//    "linux"		"@_ZN18CBaseRocketMissile19CreateRocketMissileEP11CBasePlayerPKcRK6VectorRK6QAngle"
//}

int gBeamSprite;

ConVar gCvarMaxSpread;
ConVar gCvarRound;
ConVar gCvarDelay;
ConVar gCvarDelayNextSupport;
ConVar gCvarClass;
ConVar gCvarCountPerRound;
ConVar gCvarEnable;
ConVar gCvarEnableFlare;

bool IsEnabled[MAXPLAYERS + 1];
bool IsEnabledTeam[4];
int CountAvailableSupport[MAXPLAYERS + 1];
float g_flFireSupportTimer[4];

#define DEFAULT_CLASSES "template_lawmen_lawman_leader;template_outlaws_outlaw_leader;template_sniper_security_leader;template_sniper_insurgent_leader;template_handgunner_security_leader;template_handgunner_insurgent_leader"
#define SOUND_FIRESUPPORT "misc/artillery/firesupport.ogg"

// The time in seconds (300.0 = 5 minutes)
#define ADVERT_TIMER	300.0

public void OnPluginStart()
{
	cGameConfig = LoadGameConfigFile("insurgency.games");
	if (cGameConfig == INVALID_HANDLE)
	{
		SetFailState("Fatal Error: Missing File \"insurgency.games\"!");
	}

	StartPrepSDKCall(SDKCall_Static);
	PrepSDKCall_SetFromConf(cGameConfig, SDKConf_Signature, "CBaseRocketMissile::CreateRocketMissile");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_ByValue);
	fCreateRocket = EndPrepSDKCall();
	if (fCreateRocket == INVALID_HANDLE)
	{
		SetFailState("Fatal Error: Unable to find CBaseRocketMissile::CreateRocketMissile");
	}

	gCvarMaxSpread = CreateConVar("sm_firesupport_spread", "800.0", "Max spread.", FCVAR_PROTECTED, true, 10.0);
	gCvarRound = CreateConVar("sm_firesupport_shell_num", "20.0", "Shells to fire.", FCVAR_PROTECTED, true, 1.0);
	gCvarDelay = CreateConVar("sm_firesupport_delay", "10.0", "Min delay to first shell.", FCVAR_PROTECTED, true, 1.0);
	gCvarDelayNextSupport = CreateConVar("sm_firesupport_delay_support", "60.0", "Min delay to next support.", FCVAR_PROTECTED, true, 1.0);
	gCvarClass = CreateConVar("sm_firesupport_class", DEFAULT_CLASSES, "Set fire support specialist classes.", FCVAR_PROTECTED);
	gCvarCountPerRound = CreateConVar("sm_firesupport_count", "1", "Count of available support per rounds(0 = disable)", FCVAR_PROTECTED, true, 0.0);
	gCvarEnable = CreateConVar("sm_firesupport_enable", "1", "Player can call fire support.", FCVAR_PROTECTED);
	gCvarEnableFlare = CreateConVar("sm_firesupport_enable_flare", "1", "Player can call fire support using flare.", FCVAR_PROTECTED);

	RegConsoleCmd("sm_artillery", CmdCallFS);
	RegConsoleCmd("sm_arty", CmdCallFS);
	RegConsoleCmd("sm_fs", CmdCallFS);
	RegConsoleCmd("sm_firesupport", CmdCallFS);
	RegConsoleCmd("sm_firesupport_call", CmdCallFS, "Call fire support where you looking at.", 0);
	RegAdminCmd("sm_firesupport_ad_call", CmdCallAFS, 0);										// HINT: test command

	HookEvent("round_start", Event_RoundStart);
	HookEvent("player_pick_squad", Event_PlayerPickSquad);
	HookEvent("grenade_detonate", Event_GrenadeDetonate, EventHookMode_Post);

	InitSupportCount();

	CreateTimer( ADVERT_TIMER, Timer_AdvertiseFireSupport, _, TIMER_REPEAT );
}

public Action Timer_AdvertiseFireSupport( Handle timer )
{
	PrintToChatAll( "\x03Only squad leaders can call artillery, use !fs or bind it to a key" );
	return Plugin_Continue;
}

public void OnMapStart()
{
	gBeamSprite = PrecacheModel( "sprites/laserbeam.vmt" );
	char sSoundFile[64];
	Format( sSoundFile, sizeof( sSoundFile ), "sound/%s", SOUND_FIRESUPPORT );
	AddFileToDownloadsTable( sSoundFile );

	PrecacheSound( SOUND_FIRESUPPORT, true );

	// Make sure these are precached!!!
	PrecacheSound( "weapons/rpg7/rpg_rocket_loop.wav", true );
	PrecacheModel( "models/weapons/w_rpg7_projectile.mdl" );

	// Reset on map start
	InitSupportCount();
}

// Can this client fire support?
// Results:
//	0 :: Not looking at the ground
//	1 :: Can't fire support, something is in the way!
//	2 :: Fire support was a success
public int CanFireSupport( int client, int team )
{
	float ground[3];
	if (GetAimGround(client, ground))
	{
		ground[2] += 20.0;
		if (CallFireSupport(client, ground))
		{
			CountAvailableSupport[client]--;
			IsEnabledTeam[team] = false;
			// Fire support is on the way!!
			EmitSoundToAll( SOUND_FIRESUPPORT, client, SNDCHAN_AUTO );
			CreateTimer( gCvarDelayNextSupport.FloatValue, Timer_EnableTeamSupport, team, TIMER_FLAG_NO_MAPCHANGE );
			return 2;
		}
		return 1;
	}
	return 0;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	InitSupportCount();
	return Plugin_Continue;
}

public Action Event_PlayerPickSquad(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	char template[64];
	event.GetString("class_template", template, sizeof(template), "");
	char class[250];
	gCvarClass.GetString(class, sizeof(class));

	IsEnabled[client] = (StrContains( class, template, false ) > -1);

	// Useful debug
	PrintToServer( "[Fire Support] %N >> Class: [%s] Result: [%s]", client, template, IsEnabled[client] ? "found" : "not found" ); 

	// Reset it
	CountAvailableSupport[ client ] = gCvarCountPerRound.IntValue;

	return Plugin_Continue;
}

public Action Event_GrenadeDetonate(Event event, const char[] name, bool dontBroadcast)
{
	if (!gCvarEnableFlare.BoolValue) return Plugin_Continue;

	int entity = GetEventInt(event, "entityid");
	if (entity > MaxClients)
	{
		char sGrenadeName[48];
		GetEntityClassname(entity, sGrenadeName, sizeof(sGrenadeName));
		if (!StrEqual(sGrenadeName, "grenade_flare")) return Plugin_Continue;
		int client = GetClientOfUserId(GetEventInt(event, "userid"));
		int team = GetClientTeam(client);
		if ((team != TEAM_SECURITY && team != TEAM_INSURGENT) || !IsPlayerAlive(client) || !CanCallFS_Flare(client)) {
			return Plugin_Handled;
		}
		float ground[3];
		ground[0] = GetEventFloat(event, "x");
		ground[1] = GetEventFloat(event, "y");
		ground[2] = GetEventFloat(event, "z")+20.0;
		//ground[2] += 20.0;
		float sky[3];
		if (GetSkyPos(client, ground, sky))
		{
			if (CallFireSupport(client, ground))
			{
				CountAvailableSupport[client]--;
				IsEnabledTeam[team] = false;
				// Fire support is on the way!!
				EmitSoundToAll( SOUND_FIRESUPPORT, client, SNDCHAN_AUTO );
				CreateTimer( gCvarDelayNextSupport.FloatValue, Timer_EnableTeamSupport, team, TIMER_FLAG_NO_MAPCHANGE );
			}
		}
	}
	return Plugin_Continue;
}
stock bool CanCallFS_Flare(int client)
{
	if ( !gCvarEnable.BoolValue )
		return false;

	if ( !IsEnabled[client] )
	{
		ChatHintPrint( client, "You need to be the \x03Squad Leader\x01 to use \x03fire support\x01!" );
		return false;
	}

	if ( CountAvailableSupport[client] < 1 )
	{
		ChatHintPrint( client, "Your squad is out of \x03fire support\x01!" );
		return false;
	}

	int team = GetClientTeam(client);
	if ( !IsEnabledTeam[team] )
	{
		ChatHintPrint( client, "Your team has already \x03requested fire support\x01!" );
		return false;
	}

	// Why are trying trying to fire it when you are dead?
	if ( !IsPlayerAlive(client) )
		return false;

	return true;
}

Action CmdCallFS( int client, int args )
{
	if ( !gCvarEnable.BoolValue )
		return Plugin_Handled;

	if ( !IsEnabled[client] )
	{
		ChatHintPrint( client, "You need to be the \x03Squad Leader\x01 to use \x03fire support\x01!" );
		return Plugin_Handled;
	}

	if ( CountAvailableSupport[client] < 1 )
	{
		ChatHintPrint( client, "Your squad is out of \x03fire support\x01!" );
		return Plugin_Handled;
	}

	int team = GetClientTeam(client);
	if ( !IsEnabledTeam[team] )
	{
		ChatHintPrint( client, "Your team has already \x03requested fire support\x01!" );
		return Plugin_Handled;
	}

	// Why are trying trying to fire it when you are dead?
	if ( !IsPlayerAlive(client) )
		return Plugin_Handled;

	//	0 :: Not looking at the ground
	//	1 :: Can't fire support, something is in the way!
	//	3 :: Fire support was a success
	switch( CanFireSupport( client, team ) )
	{
		case 0:
		{
			PrintToChat( client, "You need to look at the ground to call for \x03fire support\x01!" );
		}
		case 1:
		{
			PrintToChat( client, "The position you tried to call for \x03fire support\x01 is not outside, or that something is in the way!" );
		}
		case 3:
		{
			PrintToChatAll( "\x03%N\x01's squad has requested \x03fire support\x01!", client );
		}
	}
	return Plugin_Handled;
}

Action CmdCallAFS(int client, int args)
{
	float ground[3];
	if (GetAimGround(client, ground))
	{
		ground[2] += 20.0;
		if (CallFireSupport(client, ground))
		{
		}
	}
	return Plugin_Handled;
}

/// FireSupport
public bool CallFireSupport(int client, float ground[3]) {									// HINT: Fire to target pos
	float sky[3];
	if (GetSkyPos(client, ground, sky))
	{
		sky[2] -= 20.0;

		int team = GetClientTeam(client);
		g_flFireSupportTimer[team] = gCvarDelay.FloatValue;
		int shells = gCvarRound.IntValue;
		DataPack pack = new DataPack();
		pack.WriteCell(client);
		pack.WriteCell(shells);
		pack.WriteFloat(sky[0]);
		pack.WriteFloat(sky[1]);
		pack.WriteFloat(sky[2]);

		ShowDelayEffect(ground, sky, g_flFireSupportTimer[team]);

		CreateTimer(1.0, Timer_CountDown, client, TIMER_FLAG_NO_MAPCHANGE);
		CreateTimer(g_flFireSupportTimer[team] + 0.05 + GetURandomFloat(), Timer_LaunchMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
		CreateTimer(g_flFireSupportTimer[team] + 0.05 + 1.05 * shells, Timer_DataPackExpire, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
		return true;
	}

	return false;
}

void InitSupportCount()
{
	g_flFireSupportTimer[TEAM_SECURITY] = 0.0;
	g_flFireSupportTimer[TEAM_INSURGENT] = 0.0;
	IsEnabledTeam[TEAM_SECURITY] = true;
	IsEnabledTeam[TEAM_INSURGENT] = true;
	// Reset for all players
	for ( int x = 1; x <= MaxClients; x++ )
		CountAvailableSupport[ x ] = gCvarCountPerRound.IntValue;
}

void ShowDelayEffect(float ground[3], float sky[3], float time) {	// WARNING: Tempent can't alive more than 25 second. must use env_beam entity
	TE_SetupBeamPoints(ground, sky, gBeamSprite, 0, 0, 1, time, 1.0, 0.0, 5, 0.0, {255, 0, 0, 255}, 10);
	TE_SendToAll();
	TE_SetupBeamRingPoint(ground, 500.0, 0.0, gBeamSprite, 0, 0, 1, time, 5.0, 0.0, {255, 0, 0, 255}, 10, 0);
	TE_SendToAll();
}

public Action Timer_CountDown( Handle timer, int client )
{
	// Not valid
	if ( !IsValidPlayer( client ) ) return Plugin_Handled;

	// Reduce it
	int team = GetClientTeam(client);
	g_flFireSupportTimer[team] -= 1.0;

	int iTime = RoundToFloor( g_flFireSupportTimer[team] );
	char szTime[32];
	if ( iTime == 1 )
		Format( szTime, sizeof( szTime ), "Fire support in: %i second", iTime );
	else
		Format( szTime, sizeof( szTime ), "Fire support in: %i seconds", iTime );
	
	// Send to our team only
	for ( int x = 1; x <= MaxClients; x++ )
	{
		// Not valid
		if ( !IsValidPlayer( x ) ) continue;
		// Same team
		if ( GetClientTeam( x ) == team )
			PrintHintText( x, szTime );
	}

	if ( iTime >= 1 )
		CreateTimer( 1.0, Timer_CountDown, client, TIMER_FLAG_NO_MAPCHANGE );

	return Plugin_Handled;
}

public Action Timer_LaunchMissile(Handle timer, DataPack pack) {
	float dir = GetURandomFloat() * MATH_PI * 8.0;	// not 2π for good result
	float length = GetURandomFloat() * gCvarMaxSpread.FloatValue;

	pack.Reset();
	int client = pack.ReadCell();

	DataPackPos cursor = pack.Position;
	int shells = pack.ReadCell();
	pack.Position = cursor;
	pack.WriteCell(shells - 1);

	float pos[3];
	pos[0] = pack.ReadFloat() + Cosine(dir) * length;
	pos[1] = pack.ReadFloat() + Sine(dir) * length;
	pos[2] = pack.ReadFloat();

	if (ValidateClient(client))
	{
		SDKCall(fCreateRocket, client, "rocket_rpg7", pos, DOWN_VECTOR);
		if (shells > 1) {
			CreateTimer(0.05 + GetURandomFloat(), Timer_LaunchMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
		}
	}
	return Plugin_Handled;
}

public Action Timer_DataPackExpire(Handle timer, DataPack pack) {
	return Plugin_Handled;
}

public Action Timer_EnableTeamSupport(Handle timer, int team)
{
	IsEnabledTeam[team] = true;
	return Plugin_Handled;
}

/// UTILS
bool GetAimGround(int client, float vec[3]) {
	float pos[3];
	float dir[3];
	GetClientEyePosition(client, pos);
	GetClientEyeAngles(client, dir);
	Handle ray = TR_TraceRayFilterEx(pos, dir, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceWorldOnly, client);

	if (TR_DidHit(ray)) {
		TR_GetEndPosition(pos, ray);
		CloseHandle(ray);

		ray = TR_TraceRayFilterEx(pos, DOWN_VECTOR, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceWorldOnly, client);
		if (TR_DidHit(ray)) {
			TR_GetEndPosition(vec, ray);
			CloseHandle(ray);
			return true;
		}
	}

	CloseHandle(ray);
	return false;
}

bool GetSkyPos(int client, float pos[3], float vec[3])
{
	Handle ray = TR_TraceRayFilterEx(pos, UP_VECTOR, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceWorldOnly, client);

	if (TR_DidHit(ray))
	{
		char surface[64];
		TR_GetSurfaceName(ray, surface, sizeof(surface));
		if (StrEqual(surface, "TOOLS/TOOLSSKYBOX", false)) {
			TR_GetEndPosition(vec, ray);
			CloseHandle(ray);
			return true;
		}
	}

	CloseHandle(ray);
	return false;
}

public bool TraceWorldOnly(int entity, int mask, any data) {
	if(entity == data || entity > 0)
		return false;
	return true;
}

public bool ValidateClient(int client) {
	if (client < 1 || client > MaxClients) {
		return false;
	}

	if (!IsClientInGame(client))
		return false;

	return true;
}

public void ChatHintPrint( int client, const char[] msg )
{
	if ( !IsValidPlayer( client ) ) return;
	PrintToChat( client, msg );

	char szBuffer[100];
	Format( szBuffer, sizeof( szBuffer ), "%s", msg );
	// Remove color coded stuff
	ReplaceString( szBuffer, sizeof( szBuffer ), "\x01", "", false );
	ReplaceString( szBuffer, sizeof( szBuffer ), "\x03", "", false );
	PrintHintText( client, szBuffer );
}

// Is the player valid?
public bool IsValidPlayer( int client )
{
	if ( client == 0 ) return false;
	if ( !IsClientConnected( client ) ) return false;
	if ( !IsClientInGame( client ) ) return false;
	return true;
}
