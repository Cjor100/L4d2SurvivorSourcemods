#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <left4dhooks>
#include <actions>
#include <l4d2_weapons>

#define HUMAN_HALF_HEIGHT			35.5
#define MAXENTITIES	2048
#define MAP_SCAN_TIMER_INTERVAL	2.0

static Handle g_hSurvivorLegsRetreat;
static bool g_bMapStarted;
static int g_iNavArea_Parent;
static int g_iNavArea_NWCorner;
static int g_iNavArea_SECorner;
static int g_iNavArea_InvDXCorners;
static int g_iNavArea_InvDYCorners;

static Handle g_hScanMapForEntitiesTimer;

static ArrayList g_ScavengeList;

ArrayList WitchArray;
ArrayList TankArray;

ConVar survivor_max_incapacitated_count;

public void OnPluginStart()
{
	g_hScanMapForEntitiesTimer = CreateTimer(MAP_SCAN_TIMER_INTERVAL, ScanMapForEntities, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

	survivor_max_incapacitated_count = FindConVar("survivor_max_incapacitated_count");

	Handle hGameData = LoadGameConfigFile("l4d2_improved_bots");
	if (!hGameData)SetFailState("Failed to find 'l4d2_improved_bots.txt' game config.");
	
	if ((g_iNavArea_Parent = GameConfGetOffset(hGameData, "CNavArea::m_parent")) == -1)
		SetFailState("Failed to get CNavArea::m_parent offset.");
	if ((g_iNavArea_NWCorner = GameConfGetOffset(hGameData, "CNavArea::m_nwCorner")) == -1)
		SetFailState("Failed to get CNavArea::m_nwCorner offset.");
	if ((g_iNavArea_SECorner = GameConfGetOffset(hGameData, "CNavArea::m_seCorner")) == -1)
		SetFailState("Failed to get CNavArea::m_seCorner offset.");
	if ((g_iNavArea_InvDXCorners = GameConfGetOffset(hGameData, "CNavArea::m_invDxCorners")) == -1)
		SetFailState("Failed to get CNavArea::m_invDxCorners offset.");
	if ((g_iNavArea_InvDYCorners = GameConfGetOffset(hGameData, "CNavArea::m_invDyCorners")) == -1)
		SetFailState("Failed to get CNavArea::m_invDyCorners offset.");
	
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SurvivorLegsRetreat::SurvivorLegsRetreat");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	if ((g_hSurvivorLegsRetreat = EndPrepSDKCall()) == null)
		SetFailState("Failed to create SDKCall for SurvivorLegsRetreat::SurvivorLegsRetreat signature!");

    HookEvent("round_end",                 Event_RoundEnd,        EventHookMode_PostNoCopy);
    HookEvent("finale_win",             Event_RoundEnd,        EventHookMode_PostNoCopy);
    HookEvent("mission_lost",             Event_RoundEnd,        EventHookMode_PostNoCopy);
    HookEvent("map_transition",         Event_RoundEnd,        EventHookMode_PostNoCopy);
	
	TankArray = new ArrayList(1);
	WitchArray = new ArrayList(1);
}

public Action Event_RoundEnd(Event event, char[] name, bool dontBroadcast)
{
	TankArray.Clear();
	WitchArray.Clear();
}

public void OnMapStart()
{
	g_bMapStarted = true;
	
	g_ScavengeList = new ArrayList();
	
	if (!g_hScanMapForEntitiesTimer)
	{
		g_hScanMapForEntitiesTimer = CreateTimer(MAP_SCAN_TIMER_INTERVAL, ScanMapForEntities, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnMapEnd()
{
	g_bMapStarted = false;
	
	g_ScavengeList.Clear();
}

void PushEntityIntoArrayList(ArrayList hArrayList, int iEntity)
{
	if (!hArrayList)return;
	int iEntRef = EntIndexToEntRef(iEntity);
	int iArrayEnt = hArrayList.FindValue(iEntRef);
	if (iArrayEnt == -1)hArrayList.Push(iEntRef);
}

Action ScanMapForEntities(Handle timer)
{
	if (!IsServerProcessing())
		return Plugin_Continue;

	for (int i = 0; i < MAXENTITIES; i++)
	{	
		int iItemWEPID = L4D2Wep_Identify(i, IDENTIFY_SAFE);
		if (iItemWEPID == WEPID_FIRST_AID_KIT || iItemWEPID == WEPID_PAIN_PILLS || iItemWEPID == WEPID_ADRENALINE)
		{
			PushEntityIntoArrayList(g_ScavengeList, i);
		}
	}

	return Plugin_Continue;
}

int LBI_GetNavAreaParent(int iNavArea)
{
	return (LoadFromAddress(view_as<Address>(iNavArea) + view_as<Address>(g_iNavArea_Parent), NumberType_Int32));
}

void LBI_GetNavAreaCorners(int iNavArea, float fNWCorner[3], float fSECorner[3])
{
	Address hAddress = view_as<Address>(iNavArea);
	for (int i = 0; i < 3; i++)
	{
		fNWCorner[i] = view_as<float>(LoadFromAddress(hAddress + view_as<Address>(g_iNavArea_NWCorner + (4 * i)), NumberType_Int32));
		fSECorner[i] = view_as<float>(LoadFromAddress(hAddress + view_as<Address>(g_iNavArea_SECorner + (4 * i)), NumberType_Int32));
	}
}

float LBI_GetNavAreaZ(int iNavArea, float x, float y)
{
	float fNWCorner[3], fSECorner[3];
	LBI_GetNavAreaCorners(iNavArea, fNWCorner, fSECorner);

	float fInvDXCorners = view_as<float>(LoadFromAddress(view_as<Address>(iNavArea) + view_as<Address>(g_iNavArea_InvDXCorners), NumberType_Int32));
	float fInvDYCorners = view_as<float>(LoadFromAddress(view_as<Address>(iNavArea) + view_as<Address>(g_iNavArea_InvDYCorners), NumberType_Int32));

	float u = (x - fNWCorner[0]) * fInvDXCorners;
	float v = (y - fNWCorner[1]) * fInvDYCorners;
	
	u = fsel(u, u, 0.0);
	u = fsel(u - 1.0, 1.0, u);

	v = fsel(v, v, 0.0);
	v = fsel(v - 1.0, 1.0, v);

	float fNorthZ = fNWCorner[2] + u * (fSECorner[2] - fNWCorner[2]);
	float fSouthZ = fNWCorner[2] + u * (fSECorner[2] - fNWCorner[2]);

	return (fNorthZ + v * (fSouthZ - fSouthZ));
}

void LBI_GetClosestPointOnNavArea(int iNavArea, const float fPos[3], float fClosePoint[3])
{
	float fNWCorner[3], fSECorner[3];
	LBI_GetNavAreaCorners(iNavArea, fNWCorner, fSECorner);

	float fNewPos[3];
	fNewPos[0] = fsel((fPos[0] - fNWCorner[0]), fPos[0], fNWCorner[0]);
	fNewPos[0] = fsel((fNewPos[0] - fSECorner[0]), fSECorner[0], fNewPos[0]);
	
	fNewPos[1] = fsel((fPos[1] - fNWCorner[1]), fPos[1], fNWCorner[1]);
	fNewPos[1] = fsel((fNewPos[1] - fSECorner[1]), fSECorner[1], fNewPos[1]);

	fNewPos[2] = LBI_GetNavAreaZ(iNavArea, fNewPos[0], fNewPos[1]);

	fClosePoint = fNewPos;
}

bool Base_TraceFilter(int iEntity, int iContentsMask, int iData)
{
	return (iEntity == iData || HasEntProp(iEntity, Prop_Data, "m_eDoorState") && L4D_GetDoorState(iEntity) != DOOR_STATE_OPENED);
}

bool GetVectorVisible(float fStart[3], float fEnd[3], int iMask = CONTENTS_SOLID)
{
	Handle hResult = TR_TraceRayFilterEx(fStart, fEnd, iMask, RayType_EndPoint, Base_TraceFilter);
	float fFraction = TR_GetFraction(hResult); delete hResult; 
	
	if (fFraction != 1.0)
	{
		PrintToServer("Could not see boss");
	}
	
	return (fFraction == 1.0);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (!g_bMapStarted)
		return;

	static char cClassName[8];
	GetEntityClassname(entity,cClassName,sizeof(cClassName));

	if (StrEqual(cClassName, "tank"))
	{
		TankArray.Push(entity);
		PrintToServer("Found tank");
	}
	if (StrEqual(cClassName, "witch"))
	{
		WitchArray.Push(entity);
		PrintToServer("Found witch");
	}
}

int IsTankNearby(int iClient)
{
	if (!g_bMapStarted)return -1;

	float fClientAbsOrigin[3];
	GetEntPropVector(iClient, Prop_Data, "m_vecAbsOrigin", fClientAbsOrigin);
	
	float fClientViewOffset[3]; 
	GetEntPropVector(iClient, Prop_Data, "m_vecViewOffset", fClientViewOffset);
	AddVectors(fClientAbsOrigin, fClientViewOffset, fClientAbsOrigin);

	for(int iTankIndex = 0; iTankIndex < TankArray.Length; iTankIndex++)
	{
		int iTankEntity = TankArray.Get(iTankIndex);
		
		if (IsValidEntity(iTankEntity) && IsPlayerAlive(iTankEntity))
		{
			float fTankAbsOrigin[3];
			GetEntPropVector(iTankEntity, Prop_Data, "m_vecAbsOrigin", fTankAbsOrigin);
			
			float fTankViewOffset[3]; 
			GetEntPropVector(iTankEntity, Prop_Data, "m_vecViewOffset", fTankViewOffset);
			AddVectors(fTankAbsOrigin, fTankViewOffset, fTankAbsOrigin);
			
			float fTankDist = GetVectorDistance(fTankAbsOrigin, fClientAbsOrigin, true);
			if (fTankDist <= 360000) //600^2
			{
				if (GetVectorVisible(fClientAbsOrigin, fTankAbsOrigin))
				{
					return iTankEntity;
				}
			}
		}
		else
		{
			TankArray.Erase(iTankIndex);
			iTankIndex--;
			PrintToServer("Removed tank");
		}
	}

	return -1;
}

int IsWitchNearby(int iClient)
{
	if (!g_bMapStarted)return -1;

	float fClientAbsOrigin[3];
	GetEntPropVector(iClient, Prop_Data, "m_vecAbsOrigin", fClientAbsOrigin);

	float fClientViewOffset[3]; 
	GetEntPropVector(iClient, Prop_Data, "m_vecViewOffset", fClientViewOffset);
	AddVectors(fClientAbsOrigin, fClientViewOffset, fClientAbsOrigin);

	for(int iWitchIndex = 0; iWitchIndex < WitchArray.Length; iWitchIndex++)
	{
		int iWitchEntity = WitchArray.Get(iWitchIndex);
		
		if (IsValidEntity(iWitchEntity))
		{
			float fWitchAbsOrigin[3];
			GetEntPropVector(iWitchEntity, Prop_Data, "m_vecAbsOrigin", fWitchAbsOrigin);
			
			float fWitchViewOffset[3]; 
			GetEntPropVector(iWitchEntity, Prop_Data, "m_vecViewOffset", fWitchViewOffset);
			AddVectors(fWitchAbsOrigin, fWitchViewOffset, fWitchAbsOrigin);
			
			float fWitchDist = GetVectorDistance(fWitchAbsOrigin, fClientAbsOrigin, true);
			if (fWitchDist <= 360000) //600^2
			{
				if (GetVectorVisible(fClientAbsOrigin, fWitchAbsOrigin))
				{
					return iWitchEntity;
				}
			}
		}
		else
		{
			WitchArray.Erase(iWitchIndex);
			iWitchIndex--;
			PrintToServer("Removed witch");
		}
	}
	
	return -1;
}

MRESReturn DTR_OnSurvivorBotGetAvoidRange(int iClient, Handle hReturn, Handle hParams)
{
	int iTarget = DHookGetParam(hParams, 1); 
	float fAvoidRange = DHookGetReturn(hReturn);
	float fInitRange = DHookGetReturn(hReturn);
	
	if (L4D2_GetPlayerZombieClass(iTarget) != L4D2ZombieClass_Tank || L4D2_GetPlayerZombieClass(iTarget) != L4D2ZombieClass_Witch)
	{
		fAvoidRange = 1500.0;
	}

	if (fInitRange != fAvoidRange)
	{
		DHookSetReturn(hReturn, fAvoidRange);
		return MRES_ChangedOverride;
	}

	return MRES_Ignored;
}

stock bool IsValidClient(int iClient) 
{
	return (1 <= iClient <= MaxClients && IsClientInGame(iClient)); 
}

stock bool IsIncapacitated(int client)
{
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) > 0)
		return true;
	return false;
}

stock bool IsClientSurvivor(int iClient)
{
	return (IsValidClient(iClient) && GetClientTeam(iClient) == 2 && IsPlayerAlive(iClient));
}

bool SurvivorHasLowestHealth(int actor, bool bUseTempHealth)
{
	int iHealth = GetClientHealth(actor);
	if (bUseTempHealth)
	{
		iHealth = iHealth + L4D_GetPlayerTempHealth(actor);
	}
	bool bSurvivorLowestHealth = true;
	
	for (int iClient = 1; iClient <= MaxClients; iClient++)
	{
		if (!IsClientSurvivor(iClient))continue;
		
		int iCurrentHealth = GetClientHealth(iClient);
		if (bUseTempHealth)
		{
			iCurrentHealth = iCurrentHealth + L4D_GetPlayerTempHealth(iClient);
		}
		if (iCurrentHealth < iHealth)
		{
			bSurvivorLowestHealth = false;
			break;
		}
	}
	
	return bSurvivorLowestHealth;
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

float GetEntityDistance(int iEntity, int iTarget, bool bSquared = false)
{
	float fEntityPos[3]; 
	GetEntPropVector(iEntity, Prop_Data, "m_vecAbsOrigin", fEntityPos);
	
	float fTargetPos[3]; 
	GetEntPropVector(iTarget, Prop_Data, "m_vecAbsOrigin", fTargetPos);
	
	return (GetVectorDistance(fEntityPos, fTargetPos, bSquared));
}

int GetNearbyItemAmount(int iClient, int iWEPID, int iMaxDistance)
{
	int iAmount = 0;

	for (int i = 0; i < g_ScavengeList.Length; i++)
	{
		int iItem = EntRefToEntIndex(g_ScavengeList.Get(i));
		int iItemWEPID = L4D2Wep_Identify(iItem, IDENTIFY_SAFE)
			
		if (iItemWEPID != iWEPID)
		{
			continue;
		}
		
		float fItemDistance = GetEntityDistance(iClient, iItem);
					
		if (fItemDistance*fItemDistance < iMaxDistance*iMaxDistance)
		{
			iAmount++;
		}
	}
	
	return iAmount;
}

public Action OnSelfActionFirst(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	bool bThirdStrike = GetEntProp(actor, Prop_Send, "m_currentReviveCount") >= survivor_max_incapacitated_count.IntValue;
	if (bThirdStrike)
	{
		return Plugin_Continue;
	}
	
	int iTempHealing = GetPlayerWeaponSlot(actor, 4);
	int iTempHealingWEPID = L4D2Wep_Identify(iTempHealing, IDENTIFY_ALL);
	
	int iHealth = GetClientHealth(actor) + L4D_GetPlayerTempHealth(actor);
	if (iHealth < 40)
	{	
		if (iTempHealingWEPID == WEPID_NONE)
		{
			return Plugin_Continue;
		}
	}
	
	int iNearbyMedkit = GetNearbyItemAmount(actor, WEPID_FIRST_AID_KIT, 1000);
	int iTeamMedkitAmount = GetSurvivorTeamItemCount(WEPID_FIRST_AID_KIT);
	int iSurvivorTeamAliveAmount = GetSurvivorTeamAliveAmount();
	
	if (iNearbyMedkit + iTeamMedkitAmount > iSurvivorTeamAliveAmount)
	{
		if (SurvivorHasLowestHealth(actor, false))
		{
			PrintToChatAll("Found nearby medkits");
			return Plugin_Continue;
		}
	}

	result.type = DONE;
	return Plugin_Handled;
	PrintToChatAll("Blocked heal");
}

public Action OnSelfActionPills(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	int iHealth = GetClientHealth(actor) + L4D_GetPlayerTempHealth(actor);
	if (iHealth < 40)
	{
		return Plugin_Continue;
	}
	
	int iTempHealing = GetPlayerWeaponSlot(actor, 4);
	int iTempHealingWEPID = L4D2Wep_Identify(iTempHealing, IDENTIFY_ALL);
	if (iTempHealingWEPID == WEPID_ADRENALINE && L4D2_IsTankInPlay())
	{
		return Plugin_Continue;
	}
	
	if (iTempHealingWEPID == WEPID_PAIN_PILLS && iHealth < 60)
	{
		int iNearbyPills = GetNearbyItemAmount(actor, WEPID_PAIN_PILLS, 1000);
		int iTeamPillsAmount = GetSurvivorTeamItemCount(WEPID_PAIN_PILLS);
		int iSurvivorTeamAliveAmount = GetSurvivorTeamAliveAmount();
		
		if (iNearbyPills + iTeamPillsAmount > iSurvivorTeamAliveAmount)
		{
			if (SurvivorHasLowestHealth(actor, true))
			{
				PrintToChatAll("Found nearby pills");
				return Plugin_Continue;
			}
		}
	}

	result.type = DONE;
	return Plugin_Handled;
}

public Action OnFriendActionFirst(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	int iTarget = action.Get(0x34) & 0xFFF;

	int iHealing = GetPlayerWeaponSlot(iTarget, 3);
	int iHealingWEPID = L4D2Wep_Identify(iHealing, IDENTIFY_ALL);
	
	if (iHealingWEPID == WEPID_FIRST_AID_KIT)
	{
		result.type = DONE;
		return Plugin_Changed;
	}
	
	if (!SurvivorHasLowestHealth(iTarget, false))
	{
		result.type = DONE;
		return Plugin_Changed;
	}
	
	int iHealth = GetClientHealth(iTarget) + L4D_GetPlayerTempHealth(iTarget);
	if (iHealth < 40)
	{
		return Plugin_Continue;
	}
	
	int iNearbyMedkit = GetNearbyItemAmount(actor, WEPID_FIRST_AID_KIT, 1000);
	int iTeamMedkitAmount = GetSurvivorTeamItemCount(WEPID_FIRST_AID_KIT);
	int iSurvivorTeamAliveAmount = GetSurvivorTeamAliveAmount();
	
	if (iNearbyMedkit + iTeamMedkitAmount > iSurvivorTeamAliveAmount)
	{
		PrintToChatAll("Found nearby medkits");
		return Plugin_Continue;
	}

	result.type = DONE;
	return Plugin_Handled;
}

public Action OnFriendActionPills(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	return Plugin_Continue;
}

public void OnActionCreated(BehaviorAction hAction, int iActor, const char[] sName)
{
	if (strcmp(sName, "SurvivorLegsRetreat") == 0)
	{
		return;
	}
	
	if(strcmp(sName, "SurvivorHealSelf") == 0 )
	{
		hAction.OnStart = OnSelfActionFirst;
		return
	}
	
	if(strcmp(sName, "SurvivorHealFriend") == 0 )
	{
		hAction.OnStartPost = OnFriendActionFirst;
		return
	}
	
	if(strcmp(sName, "SurvivorTakePills") == 0 )
	{
		hAction.OnStart = OnSelfActionPills;
		return
	}
	
	if(strcmp(sName, "SurvivorGivePillsToFriend") == 0 )
	{
		hAction.OnStartPost = OnFriendActionPills;
		return
	}

	if (!IsValidClient(iActor) || !IsClientInGame(iActor) || !IsPlayerAlive(iActor) || GetClientTeam(iActor) != 2 || !IsFakeClient(iActor) && IsIncapacitated(iActor))
	{
		return;
	}

	if (strncmp(sName, "SurvivorLegs", 12) == 0)
	{
		int iNearbyTank = IsTankNearby(iActor);
		if (iNearbyTank != -1)
		{
			hAction.OnStart = OnRetreatTankAction;
			hAction.OnUpdate = OnRetreatTankAction;
			return;
		}
	}
	
	if (strcmp(sName, "SurvivorLegsMoveOn") == 0 || strcmp(sName, "SurvivorLegsCoverFriendInCombat") == 0 || strcmp(sName, "SurvivorLegsApproach") == 0  || strcmp(sName, "SurvivorLegsWait") == 0)
	{
		int iNearbyWitch = IsWitchNearby(iActor);
		if (iNearbyWitch != -1)
		{
			hAction.OnStart = OnRetreatWitchAction;
			hAction.OnUpdate = OnRetreatWitchAction;
			return;
		}
	}
	
	if(strcmp(sName, "SurvivorLegsCoverOrphan") == 0 || strcmp(sName, "SurvivorLegsBattleStations") == 0)
	{
		hAction.OnStart = BlockAction;
	}
}

public Action BlockAction(BehaviorAction action, int actor, BehaviorAction priorAction, ActionResult result)
{
	result.type = DONE;
	return Plugin_Changed;
}


Action OnRetreatTankAction(BehaviorAction hAction, int iActor, float fInterval, ActionResult hResult)
{
	int iNearbyTank = IsTankNearby(iActor);
	if (iNearbyTank == -1)return Plugin_Continue;

	if (iNearbyTank != 0)
	{
		PrintToServer("Retreating from tank!");
	
		hResult.type = SUSPEND_FOR;
		hResult.action = CreateSurvivorLegsRetreatAction(iNearbyTank);
		return Plugin_Handled;
	}

	hResult.type = DONE;
	return Plugin_Changed;
}

Action OnRetreatWitchAction(BehaviorAction hAction, int iActor, float fInterval, ActionResult hResult)
{
	int iNearbyWitch = IsWitchNearby(iActor);
	if (iNearbyWitch == -1)return Plugin_Continue;

	if (iNearbyWitch != 0)
	{
		PrintToServer("Retreating from witch!");
	
		hResult.type = SUSPEND_FOR;
		hResult.action = CreateSurvivorLegsRetreatAction(iNearbyWitch);
		return Plugin_Handled;
	}

	hResult.type = DONE;
	return Plugin_Changed;
}

stock float fsel(float fComparand, float fValGE, float fLT)
{
	return (fComparand >= 0.0 ? fValGE : fLT);
}

BehaviorAction CreateSurvivorLegsRetreatAction(int iThreat)
{
	BehaviorAction hAction = ActionsManager.Allocate(0x745A);
	SDKCall(g_hSurvivorLegsRetreat, hAction, iThreat);
	return hAction;
}