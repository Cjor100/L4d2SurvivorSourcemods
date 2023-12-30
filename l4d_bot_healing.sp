#define PLUGIN_VERSION 		"2.2"

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#undef REQUIRE_EXTENSIONS
#include <sourcescramble>
#include <actions>
#include <l4d2_weapons>
#define REQUIRE_EXTENSIONS



#define CVAR_FLAGS			FCVAR_NOTIFY
#define GAMEDATA			"l4d_bot_healing"


bool g_bLeft4Dead2;
ConVar g_hCvarMaxIncap, g_hCvarFirst, g_hCvarPills, g_hCvarDieFirst, g_hCvarDiePills;
float g_fCvarFirst, g_fCvarPills;
bool g_bCvarDieFirst, g_bCvarDiePills;
int g_iCvarMaxIncap;

MemoryPatch g_hPatchFirst1;
MemoryPatch g_hPatchFirst2;
MemoryPatch g_hPatchPills1;
MemoryPatch g_hPatchPills2;

// From "Heartbeat" plugin
bool g_bExtensionActions;
bool g_bExtensionScramble;
bool g_bPluginHeartbeat;
native int Heartbeat_GetRevives(int client);

Handle g_hSurvivorLegsRegroup;

// ====================================================================================================
//					PLUGIN INFO / START / END
// ====================================================================================================
public Plugin myinfo =
{
	name = "[L4D & L4D2] Bot Healing Values",
	author = "SilverShot",
	description = "Set the health value bots require before using First Aid, Pain Pills or Adrenaline.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=338889"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();

	if( test == Engine_Left4Dead ) g_bLeft4Dead2 = false;
	else if( test == Engine_Left4Dead2 ) g_bLeft4Dead2 = true;
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	MarkNativeAsOptional("Heartbeat_GetRevives");

	return APLRes_Success;
}

public void OnLibraryAdded(const char[] name)
{
	if( strcmp(name, "l4d_heartbeat") == 0 )
	{
		g_bPluginHeartbeat = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if( strcmp(name, "l4d_heartbeat") == 0 )
	{
		g_bPluginHeartbeat = false;
	}
}

public void OnPluginStart()
{
	// ====================
	// Validate extensions
	// ====================
	g_bExtensionActions = LibraryExists("actionslib");
	g_bExtensionScramble = GetFeatureStatus(FeatureType_Native, "MemoryPatch.CreateFromConf") == FeatureStatus_Available;

	if( !g_bExtensionActions && !g_bExtensionScramble )
	{
		SetFailState("\n==========\nMissing required extensions: \"Actions\" or \"SourceScramble\".\nRead installation instructions again.\n==========");
	}



	// ====================
	// Load GameData
	// ====================
	if( g_bExtensionScramble )
	{
		char sPath[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
		if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\nRead installation instructions again.\n==========", sPath);

		GameData hGameData = new GameData(GAMEDATA);
		if( hGameData == null ) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

		StartPrepSDKCall(SDKCall_Raw);
		PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SurvivorLegsRegroup");
		PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
		g_hSurvivorLegsRegroup = EndPrepSDKCall();

		// ====================
		// Enable patches
		// ====================
		g_hPatchFirst1 = MemoryPatch.CreateFromConf(hGameData, "BotHealing_FirstAid_A");
		if( !g_hPatchFirst1.Validate() ) SetFailState("Failed to validate \"BotHealing_FirstAid_A\" target.");
		if( !g_hPatchFirst1.Enable() ) SetFailState("Failed to patch \"BotHealing_FirstAid_A\" target.");

		g_hPatchFirst2 = MemoryPatch.CreateFromConf(hGameData, "BotHealing_FirstAid_B");
		if( !g_hPatchFirst2.Validate() ) SetFailState("Failed to validate \"BotHealing_FirstAid_B\" target.");
		if( !g_hPatchFirst2.Enable() ) SetFailState("Failed to patch \"BotHealing_FirstAid_B\" target.");

		g_hPatchPills1 = MemoryPatch.CreateFromConf(hGameData, "BotHealing_Pills_A");
		if( !g_hPatchPills1.Validate() ) SetFailState("Failed to validate \"BotHealing_Pills_A\" target.");
		if( !g_hPatchPills1.Enable() ) SetFailState("Failed to patch \"BotHealing_Pills_A\" target.");

		g_hPatchPills2 = MemoryPatch.CreateFromConf(hGameData, "BotHealing_Pills_B");
		if( !g_hPatchPills2.Validate() ) SetFailState("Failed to validate \"BotHealing_Pills_B\" target.");
		if( !g_hPatchPills2.Enable() ) SetFailState("Failed to patch \"BotHealing_Pills_B\" target.");



		// ====================
		// Patch memory
		// ====================
		// First Aid
		StoreToAddress(g_hPatchFirst1.Address + view_as<Address>(2), GetAddressOfCell(g_fCvarFirst), NumberType_Int32);
		StoreToAddress(g_hPatchFirst2.Address + view_as<Address>(2), GetAddressOfCell(g_fCvarFirst), NumberType_Int32);

		// Pills
		StoreToAddress(g_hPatchPills1.Address + view_as<Address>(2), GetAddressOfCell(g_fCvarPills), NumberType_Int32);
		StoreToAddress(g_hPatchPills2.Address + view_as<Address>(2), GetAddressOfCell(g_fCvarPills), NumberType_Int32);
	}



	// ====================
	// ConVars
	// ====================
	if( !g_bLeft4Dead2 )
	{
		g_hCvarMaxIncap = FindConVar("survivor_max_incapacitated_count");
		g_hCvarMaxIncap.AddChangeHook(ConVarChanged_Cvars);
	}

	g_hCvarDieFirst = CreateConVar("l4d_bot_healing_die_first", "0", "0=Ignored. 1=Only allowing healing when self or target is black and white (Requires \"Actions\" extension).", CVAR_FLAGS);
	g_hCvarDiePills = CreateConVar("l4d_bot_healing_die_pills", "0", "0=Ignored. 1=Only allowing healing or giving pills when self or target is black and white (Requires \"Actions\" extension).", CVAR_FLAGS);
	g_hCvarFirst = CreateConVar("l4d_bot_healing_first", g_bLeft4Dead2 ? "30.0" : "40.0", "Allow bots to use First Aid when their health is below this value.", CVAR_FLAGS);
	g_hCvarPills = CreateConVar("l4d_bot_healing_pills", g_bLeft4Dead2 ? "50.0" : "60.0", "Allow bots to use Pills or Adrenaline when their health is below this value.", CVAR_FLAGS);
	CreateConVar("l4d_bot_healing_version", PLUGIN_VERSION, "Bot Healing Values plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig(true, "l4d_bot_healing");

	g_hCvarFirst.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarPills.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarDieFirst.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarDiePills.AddChangeHook(ConVarChanged_Cvars);
}

public void OnPluginEnd()
{
	if( g_bExtensionScramble )
	{
		g_hPatchFirst1.Disable();
		g_hPatchFirst2.Disable();
		g_hPatchPills1.Disable();
		g_hPatchPills2.Disable();
	}
}

public void OnConfigsExecuted()
{
	GetCvars();
}

void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	if( !g_bLeft4Dead2 )
		g_iCvarMaxIncap = g_hCvarMaxIncap.IntValue;

	g_bCvarDieFirst = g_hCvarDieFirst.BoolValue;
	g_bCvarDiePills = g_hCvarDiePills.BoolValue;

	g_fCvarFirst = g_hCvarFirst.FloatValue;
	g_fCvarPills = g_hCvarPills.FloatValue;
}



// ====================================================================================================
//					ACTIONS EXTENSION
// ====================================================================================================
public void OnActionCreated(BehaviorAction action, int actor, const char[] name)
{
	if( strncmp(name, "Survivor", 8) == 0 )
	{
		/* Hooking self healing action (when bot wants to heal self) */
		if(strcmp(name, "SurvivorHealSelf") == 0 )
		{
			action.OnStart = OnSelfActionFirst;
		}

		/* Hooking friend healing action (when bot wants to heal someone) */
		else if(strcmp(name, "SurvivorHealFriend") == 0 )
		{
			action.OnStartPost = OnFriendActionFirst;
		}

		/* Hooking take pills action (when bot wants to take pills) */
		else if(strcmp(name, "SurvivorTakePills") == 0 )
		{
			action.OnStart = OnSelfActionPills;
		}

		/* Hooking give pills action (when bot wants to give pills) */
		else if(strcmp(name, "SurvivorGivePillsToFriend") == 0 )
		{
			action.OnStartPost = OnFriendActionPills;
		}
	}
}

stock bool IsValidClient(int iClient) 
{
	return (1 <= iClient <= MaxClients && IsClientInGame(iClient)); 
}

stock bool IsClientSurvivor(int iClient)
{
	return (IsValidClient(iClient) && GetClientTeam(iClient) == 2 && IsPlayerAlive(iClient));
}

bool IsEntityExists(int iEntity)
{
	return (iEntity > 0 && (iEntity <= 2048 && IsValidEdict(iEntity) || IsValidEntity(iEntity)));
}

bool LBI_IsPositionInsideCheckpoint(const float fPos[3])
{
	if (!L4D2_IsGenericCooperativeMode())
		return false;

	Address pNavArea = view_as<Address>(L4D_GetNearestNavArea(fPos));
	if (pNavArea == Address_Null)return false;

	int iAttributes = L4D_GetNavArea_SpawnAttributes(pNavArea);
	return ((iAttributes & NAV_SPAWN_FINALE) == 0 && (iAttributes & NAV_SPAWN_CHECKPOINT) != 0);
}

int GetSurvivorTeamItemCount(int iItemWEPID)
{
	int iItemSlot = L4D2Wep_GetSlotByID(iItemWEPID);

	int iItemCount = 0;

	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientSurvivor(iClient))continue;
		
		int iClientItem = GetPlayerWeaponSlot(iClient, iItemSlot);
		int iClientItemWEPID = L4D2Wep_Identify(iClientItem, IDENTIFY_HOLD);
		
		if (iClientItemWEPID == iItemWEPID)
		{
			iItemCount++;
		}
	}
	
	return iItemCount;
}

int GetSurvivorTeamAliveAmount()
{
	int iAliveAmount = 0;
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientSurvivor(iClient))continue;
		
		iAliveAmount++;
	}
	
	return iAliveAmount;
}

bool ShouldUseMedkit(int actor)
{
	bool bThirdStrike = g_bLeft4Dead2 ? GetEntProp(actor, Prop_Send, "m_bIsOnThirdStrike") == 1 : (g_bPluginHeartbeat ? Heartbeat_GetRevives(actor) : GetEntProp(actor, Prop_Send, "m_currentReviveCount")) >= g_iCvarMaxIncap;
	if (bThirdStrike)
	{
		return true;
	}
	
	int iHealth = GetClientHealth(actor) + L4D_GetPlayerTempHealth(actor);
	if (iHealth < 40)
	{
		int iTempHealing = GetPlayerWeaponSlot(actor, 4);
		int iTempHealingWEPID = L4D2Wep_Identify(iTempHealing, IDENTIFY_ALL);
		if (iTempHealingWEPID == WEPID_NONE)
		{
			return true;
		}
	}
	
	iHealth = GetClientHealth(actor);
	if (iHealth < 60)
	{
		int iTeamFirstAidAmount = GetSurvivorTeamItemCount(WEPID_FIRST_AID_KIT);
		int iTeamDefibAmount = GetSurvivorTeamItemCount(WEPID_DEFIBRILLATOR);
		int iTeamFirstAidDefibAmount = iTeamFirstAidAmount + iTeamDefibAmount;
		int iSurvivorTeamAliveAmount = GetSurvivorTeamAliveAmount();
		
		if (iTeamFirstAidDefibAmount == iSurvivorTeamAliveAmount)
		{
			if (iTeamFirstAidAmount > iTeamDefibAmount)
			{
				return true;
			}
		}
	}

	return false;
}

bool HasMedkit(int actor)
{
	int iHealing = GetPlayerWeaponSlot(actor, 3);
	int iHealingWEPID = L4D2Wep_Identify(iHealing, IDENTIFY_ALL);
	return iHealingWEPID == WEPID_FIRST_AID_KIT;
}

public Action OnSelfActionFirst(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	float fClientLocation[3];
	GetEntPropVector(actor, Prop_Data, "m_vecOrigin", fClientLocation);
	bool bInCheckpoint = LBI_IsPositionInsideCheckpoint(fClientLocation);
	if (bInCheckpoint)
	{
		result.type = CONTINUE;
		return Plugin_Changed;
	}

	result.type = ShouldUseMedkit(actor) ? CONTINUE : DONE;
	return Plugin_Changed;
}

bool ShouldUsePills(int actor)
{
	if (HasMedkit(actor) && ShouldUseMedkit(actor))
	{
		return false;
	}

	int iHealth = GetClientHealth(actor) + L4D_GetPlayerTempHealth(actor);
	if (iHealth < 40)
	{
		return true;
	}
	
	if (iHealth < 60)
	{
		if (L4D2_IsTankInPlay())
		{
			return true;
		}
	
		int iSurvivorTeamAliveAmount = GetSurvivorTeamAliveAmount();
	
		int iTeamPillsAmount = GetSurvivorTeamItemCount(WEPID_PAIN_PILLS);
		if (iTeamPillsAmount == iSurvivorTeamAliveAmount)
		{
			return true;
		}
		
		int iTempHealing = GetPlayerWeaponSlot(actor, 4);
		int iTempHealingWEPID = L4D2Wep_Identify(iTempHealing, IDENTIFY_ALL);
		if (iTempHealingWEPID == WEPID_ADRENALINE)
		{
			int iTeamPillsAdrenalineAmount = iTeamPillsAmount + GetSurvivorTeamItemCount(WEPID_ADRENALINE);
			if (iTeamPillsAdrenalineAmount == iSurvivorTeamAliveAmount)
			{
				return true;
			}
		}
	}
}

public Action OnSelfActionPills(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	result.type = ShouldUsePills(actor) ? CONTINUE : DONE;
	return Plugin_Changed;
}

public Action OnFriendActionFirst(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	if (ShouldUsePills(actor))
	{
		result.type = DONE;
		return Plugin_Changed;
	}

	int target = action.Get(0x34) & 0xFFF;
	if (!IsValidEntity(target))
	{
		result.type = DONE;
		return Plugin_Changed;
	}
	
	if (HasMedkit(target))
	{
		result.type = DONE;
		return Plugin_Changed;
	}

	result.type = ShouldUseMedkit(target) ? CONTINUE : DONE;
	return Plugin_Changed;
}

public Action OnFriendActionPills(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	if (!L4D2_IsTankInPlay() && ShouldUseMedkit(actor))
	{
		result.type = DONE;
		return Plugin_Changed;
	}

	int target = action.Get(0x34) & 0xFFF;
	if (!IsValidEntity(target))
	{
		result.type = DONE;
		return Plugin_Changed;
	}
	
	result.type = ShouldUsePills(target) ? CONTINUE : DONE;
	return Plugin_Changed;
}