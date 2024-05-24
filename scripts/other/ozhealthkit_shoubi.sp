 /*
 *	[INS] Healthkit Script
 *	
 *	This program is free software: you can redistribute it and/or modify
 *	it under the terms of the GNU General Public License as published by
 *	the Free Software Foundation, either version 3 of the License, or
 *	(at your option) any later version.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_DESCRIPTION "Healthkit plugin"
#define PLUGIN_VERSION "2.0"

//LUA Healing define values
#define Healthkit_Timer_Tickrate			0.8		// Basic Sound has 0.8 loop
#define Healthkit_Timer_Timeout				30.0 //1.5 minutes
#define Healthkit_Radius					700.0
#define Healthkit_Remove_Type				"1"
#define Healthkit_Healing_Per_Tick_Min		1
#define Healthkit_Healing_Per_Tick_Max		3
#define MAX_ENTITIES 2048

int g_iBeaconBeam,
g_iBeaconHalo;
float g_fLastHeight[2048] = {0.0, ...},
g_fTimeCheck[2048] = {0.0, ...},
g_iTimeCheckHeight[2048] = {0.0, ...};

int g_ammoResupplyAmt[MAX_ENTITIES+1];

// Plugin info
public Plugin myinfo =
{
	name = "[DOI] Healthkit",
	author = "ozzy, original D.Freddo",
	version = PLUGIN_VERSION,
	description = PLUGIN_DESCRIPTION
}

public void OnPluginStart()
{
	CreateConVar("Lua_Ins_Healthkit", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_NOTIFY | FCVAR_DONTRECORD);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("grenade_thrown", Event_GrenadeThrown);
}

public void OnMapStart()
{
	g_iBeaconBeam = PrecacheModel("sprites/laserbeam.vmt");
	g_iBeaconHalo = PrecacheModel("sprites/glow01.vmt");
	
	// Healing sounds
	PrecacheSound("Lua_sounds/healthkit_complete.wav");
	PrecacheSound("Lua_sounds/healthkit_healing.wav");
	
	// Destory, Flip sounds
	PrecacheSound("Lua_sounds/dissolve.ogg");
	PrecacheSound("ui/sfx/cl_click.wav");
	
	// Deploying sounds
	PrecacheSound("lua_sounds/medic/medic_letme_heal1.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal2.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal3.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal4.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal5.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal6.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal7.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal8.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal9.ogg");
	PrecacheSound("lua_sounds/medic/medic_letme_heal10.ogg");
}

public void OnPluginEnd()
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "entity_healthkit")) != -1)
	{
		AcceptEntityInput(ent, "Kill");
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "entity_healthkit")) != -1)
	{
		RemoveHealthkit(ent);
	}
}

public void Event_GrenadeThrown(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int nade_id = event.GetInt("entityid");
	
	if (IsValidEntity(nade_id) && client > -1)
	{
		if (IsPlayerAlive(client))
		{
			char grenade_name[32];
			GetEntityClassname(nade_id, grenade_name, sizeof(grenade_name));
			
			if (StrEqual(grenade_name, "entity_healthkit"))
			{
				switch(GetRandomInt(1, 10))
				{
					case 1: EmitSoundToAll("lua_sounds/medic/medic_letme_heal1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 2: EmitSoundToAll("lua_sounds/medic/medic_letme_heal2.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 3: EmitSoundToAll("lua_sounds/medic/medic_letme_heal3.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 4: EmitSoundToAll("lua_sounds/medic/medic_letme_heal4.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 5: EmitSoundToAll("lua_sounds/medic/medic_letme_heal5.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 6: EmitSoundToAll("lua_sounds/medic/medic_letme_heal6.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 7: EmitSoundToAll("lua_sounds/medic/medic_letme_heal7.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 8: EmitSoundToAll("lua_sounds/medic/medic_letme_heal8.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 9: EmitSoundToAll("lua_sounds/medic/medic_letme_heal9.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
					case 10: EmitSoundToAll("lua_sounds/medic/medic_letme_heal10.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
				}
			}
		}
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity < 1) {
		return;
	}

	char classname[255];
	GetEntityClassname(entity, classname, sizeof(classname));
	
	if (StrEqual(classname, "entity_healthkit"))
	{
		StopSound(entity, SNDCHAN_STATIC, "Lua_sounds/healthkit_healing.wav");
	}
	
	if (StrContains(classname, "wcache_crate_01") == 0)
	{
		g_ammoResupplyAmt[entity] = 0; 
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "entity_healthkit"))
	{
		SDKHook(entity, SDKHook_SpawnPost, OnSpawnPost);
	}
}

public void OnSpawnPost(int entity) {
	int entref = EntIndexToEntRef(entity);
	
	DataPack hDatapack;
	CreateDataTimer(Healthkit_Timer_Tickrate, Timer_Healthkit, hDatapack, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	hDatapack.WriteCell(entref);
	hDatapack.WriteFloat(GetGameTime() + Healthkit_Timer_Timeout);
	
	g_fLastHeight[entity] = -9999.0;
	g_iTimeCheckHeight[entity] = -9999.0;
	
	SDKHook(entity, SDKHook_VPhysicsUpdate, HealthkitGroundCheck);
	CreateTimer(0.1, HealthkitGroundCheckTimer, entref, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

public Action HealthkitGroundCheck(int entity, int activator, int caller, UseType type, float value) 
{
	float fOrigin[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);

	float iRoundHeight = (fOrigin[2]);

	if (iRoundHeight != g_iTimeCheckHeight[entity]) 
	{
		g_iTimeCheckHeight[entity] = iRoundHeight;
		g_fTimeCheck[entity] = GetGameTime();
	}

	return Plugin_Continue;
}

public Action HealthkitGroundCheckTimer(Handle timer, any entref)
{
	int entity = EntRefToEntIndex(entref);

	if (IsValidEntity(entity))
	{
		float fGameTime = GetGameTime();

		if (fGameTime - g_fTimeCheck[entity] >= 1.0)
		{
			float fOrigin[3];
			GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);

			int iRoundHeight = RoundFloat(fOrigin[2]);

			if (iRoundHeight == g_iTimeCheckHeight[entity])
			{
				g_fTimeCheck[entity] = GetGameTime();

				SDKUnhook(entity, SDKHook_VPhysicsUpdate, HealthkitGroundCheck);
				SDKHook(entity, SDKHook_VPhysicsUpdate, OnEntityPhysicsUpdate);
			}
		}
	}

	return Plugin_Continue;
}

public Action OnEntityPhysicsUpdate(int entity, int activator, int caller, UseType type, float value)
{
	TeleportEntity(entity, NULL_VECTOR, NULL_VECTOR, view_as<float> ({0.0, 0.0, 0.0}));
	return Plugin_Continue;
}

public Action Timer_Healthkit(Handle timer, DataPack hDatapack)
{
	hDatapack.Reset();

	int entity = EntRefToEntIndex(hDatapack.ReadCell());
	float fEndTime = hDatapack.ReadFloat();

	if (!IsValidEntity(entity)) {
		return Plugin_Stop;
	}

	if (fEndTime <= GetGameTime()) {
		RemoveHealthkit(entity);
		return Plugin_Stop;
	}

	float fOrigin[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fOrigin);

	if (g_fLastHeight[entity] == -9999.0)
	{
		g_fLastHeight[entity] = 0.0;
	}

	EmitSoundToAll("Lua_sounds/healthkit_healing.wav", entity, SNDCHAN_STATIC, _, _, 1.0);

	fOrigin[2] += 1.0;

	TE_SetupBeamRingPoint(fOrigin, 15.0, Healthkit_Radius * 0.55, g_iBeaconBeam, g_iBeaconHalo, 0, 5, 1.0, 1.0, 2.0, {0, 204, 100, 255}, 1,0);
	TE_SendToAll();

	fOrigin[2] -= 16.0;

	if (fOrigin[2] != g_fLastHeight[entity])
	{
		g_fLastHeight[entity] = fOrigin[2];
	}
	else
	{
		float fAng[3];
		GetEntPropVector(entity, Prop_Send, "m_angRotation", fAng);

		if (fAng[1] > 89.0 || fAng[1] < -89.0)
			fAng[1] = 90.0;
		
		if (fAng[2] > 89.0 || fAng[2] < -89.0)
		{
			fAng[2] = 0.0;
			fOrigin[2] -= 6.0;

			TeleportEntity(entity, fOrigin, fAng, view_as<float>({0.0, 0.0, 0.0}));
			fOrigin[2] += 6.0;
		}
	}

	float fPlayerOrigin[3]; DataPack hData; Handle trace; int iMaxHealth; int iHealth;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i)) {
			continue;
		}

		GetClientEyePosition(i, fPlayerOrigin);

		if (GetVectorDistance(fPlayerOrigin, fOrigin) <= Healthkit_Radius)
		{
			hData = new DataPack();
			hData.WriteCell(entity);
			hData.WriteCell(i);

			fOrigin[2] += 32.0;
			trace = TR_TraceRayFilterEx(fPlayerOrigin, fOrigin, MASK_SOLID, RayType_EndPoint, Filter_ClientSelf, hData);
			delete hData;

			if (!TR_DidHit(trace))
			{
				iMaxHealth = GetEntProp(i, Prop_Data, "m_iMaxHealth");
				iHealth = GetEntProp(i, Prop_Data, "m_iHealth");

				if (iMaxHealth > iHealth)
				{
					iHealth += GetRandomInt(Healthkit_Healing_Per_Tick_Min, Healthkit_Healing_Per_Tick_Max);
					
					if (iHealth >= iMaxHealth)
					{
						iHealth = iMaxHealth;
						PrintCenterText(i, "Healed !\n\n \n %d %%\n \n \n \n \n \n \n \n", iMaxHealth);
						//EmitSoundToAll("Lua_sounds/healthkit_complete.wav", entity, _, _, _, 0.1);
					}
					else
						PrintCenterText(i, "Healing...\n\n \n   %d %%\n \n \n \n \n \n \n \n", iHealth);
					
					SetEntProp(i, Prop_Data, "m_iHealth", iHealth);
				}
			}

			delete trace;
		}
	}

	return Plugin_Continue;
}

public bool Filter_ClientSelf(int entity, int contentsMask, DataPack dp) 
{
	dp.Reset();

	int client = dp.ReadCell();
	int player = dp.ReadCell();

	return (entity != client && entity != player);
}

void RemoveHealthkit(int entity)
{
	if (IsValidEntity(entity))
	{
		StopSound(entity, SNDCHAN_STATIC, "Lua_sounds/healthkit_healing.wav");
		EmitSoundToAll("Lua_sounds/dissolve.ogg", entity, _, _, _, 0.5);

		int dissolver = CreateEntityByName("env_entity_dissolver");

		if (IsValidEntity(dissolver))
		{
			DispatchKeyValue(dissolver, "dissolvetype", Healthkit_Remove_Type);
			DispatchKeyValue(dissolver, "magnitude", "1");
			DispatchKeyValue(dissolver, "target", "!activator");
			DispatchSpawn(dissolver);
			
			AcceptEntityInput(dissolver, "Dissolve", entity);
			AcceptEntityInput(dissolver, "Kill");
		}
	}
}
