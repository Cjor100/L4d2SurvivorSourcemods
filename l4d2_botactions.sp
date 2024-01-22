#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <left4dhooks>
#include <actions>

#define HUMAN_HALF_HEIGHT			35.5

static Handle g_hSurvivorLegsRetreat;
static bool g_bMapStarted;
static int g_iNavArea_Parent;
static int g_iNavArea_NWCorner;
static int g_iNavArea_SECorner;
static int g_iNavArea_InvDXCorners;
static int g_iNavArea_InvDYCorners;

ArrayList WitchArray;
ArrayList TankArray;

public void OnPluginStart()
{
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
}

public void OnMapEnd()
{
	g_bMapStarted = false;
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
	GetEntPropVector(iClient, Prop_Data, "m_vecOrigin", fClientAbsOrigin);

	for(int iTankIndex = 0; iTankIndex < TankArray.Length; iTankIndex++)
	{
		int iTankEntity = TankArray.Get(iTankIndex);
		
		if (IsValidEntity(iTankEntity) && IsPlayerAlive(iTankEntity))
		{
			float fTankAbsOrigin[3];
			GetEntPropVector(iTankEntity, Prop_Data, "m_vecOrigin", fTankAbsOrigin);
			
			float fTankDist = GetVectorDistance(fTankAbsOrigin, fClientAbsOrigin, true);
			if (fTankDist <= 640000) //800^2
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
	GetEntPropVector(iClient, Prop_Data, "m_vecOrigin", fClientAbsOrigin);

	for(int iWitchIndex = 0; iWitchIndex < WitchArray.Length; iWitchIndex++)
	{
		int iWitchEntity = WitchArray.Get(iWitchIndex);
		
		if (IsValidEntity(iWitchEntity))
		{
			float fWitchAbsOrigin[3];
			GetEntPropVector(iWitchEntity, Prop_Data, "m_vecOrigin", fWitchAbsOrigin);
			
			float fWitchDist = GetVectorDistance(fWitchAbsOrigin, fClientAbsOrigin, true);
			if (fWitchDist <= 640000) //600^2
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

public void OnActionCreated(BehaviorAction hAction, int iActor, const char[] sName)
{
	if (strcmp(sName, "SurvivorLegsRetreat") == 0)
	{
		return;
	}
	
	if (!IsValidClient(iActor) || !IsClientInGame(iActor) || !IsPlayerAlive(iActor) || GetClientTeam(iActor) != 2 || !IsFakeClient(iActor) && IsIncapacitated(iActor))
	{
		return;
	}

	int iNearbyTank = IsTankNearby(iActor);
	int iNearbyWitch = IsWitchNearby(iActor);
	if (iNearbyTank != -1)
	{	
		if (strncmp(sName, "SurvivorLegs", 12) == 0)
		{
			hAction.OnStart = OnRetreatTankAction;
			hAction.OnUpdate = OnRetreatTankAction;
		}
		else if (strcmp(sName, "SurvivorLiberateBesiegedFriend") == 0 || strncmp(sName, "SurvivorEscape", 14) == 0 || strncmp(sName, "SurvivorCollectObject", 14) == 0)
		{
			hAction.OnStart = OnRetreatTankAction;
			hAction.OnUpdate = OnRetreatTankAction;
		}
	}
	else if (iNearbyWitch != -1)
	{
		if (strcmp(sName, "SurvivorLiberateBesiegedFriend") == 0 || strncmp(sName, "SurvivorEscape", 14) == 0
		|| strcmp(sName, "SurvivorLegsMoveOn") == 0 || strcmp(sName, "SurvivorLegsStayClose") == 0 || strcmp(sName, "SurvivorLegsApproach") == 0 || strcmp(sName, "SurvivorCollectObject") == 0)
		{
			hAction.OnStart = OnRetreatWitchAction;
			hAction.OnUpdate = OnRetreatWitchAction;
		}
	}
	else if(strcmp(sName, "SurvivorLegsCoverOrphan") == 0 || strcmp(sName, "SurvivorLegsBattleStations") == 0)
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