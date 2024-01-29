#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <left4dhooks>
#include <l4d2_weapons>

#define MAXENTITIES	2048
#define MAP_SCAN_TIMER_INTERVAL	2.0

static Handle g_hScanMapForEntitiesTimer;
static Handle g_hCalcAbsolutePosition;

static ArrayList g_ScavengeList;

void CreateAllSDKCalls(Handle hGameData)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CBaseEntity::CalcAbsolutePosition");
	if ((g_hCalcAbsolutePosition = EndPrepSDKCall()) == null) 
		SetFailState("Failed to create SDKCall for CBaseEntity::CalcAbsolutePosition signature!");
}

public void OnPluginStart()
{
	g_hScanMapForEntitiesTimer = CreateTimer(MAP_SCAN_TIMER_INTERVAL, ScanMapForEntities, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

	Handle hGameConfig = LoadGameConfigFile("l4d2_improved_bots");
	if (!hGameConfig)SetFailState("Failed to find 'l4d2_improved_bots.txt' game config.");
	
	CreateAllSDKCalls(hGameConfig);
	L4D2Wep_Init();
	L4D2Wep_InitAmmoCvars();
}

public void OnMapStart()
{
	CreateEntityArrayLists();
	if (!g_hScanMapForEntitiesTimer)
	{
		g_hScanMapForEntitiesTimer = CreateTimer(MAP_SCAN_TIMER_INTERVAL, ScanMapForEntities, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnMapEnd()
{
	delete g_hScanMapForEntitiesTimer;
	ClearEntityArrayLists();
}

void CreateEntityArrayLists()
{
	g_ScavengeList			= new ArrayList();
}

void ClearEntityArrayLists()
{
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
		int iItemWEPID = L4D2Wep_Identify(i, IDENTIFY_ALL);
		if (iItemWEPID != WEPID_NONE)
		{
			PushEntityIntoArrayList(g_ScavengeList, i);
		}
	}

	return Plugin_Continue;
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

bool IsValidVector(const float fVector[3])
{
	int iCheck;
	for (int i = 0; i < 3; ++i)
	{
		if (fVector[i] != 0.0000)break;
		++iCheck;
	}
	return view_as<bool>(iCheck != 3);
}

stock bool GetEntityAbsOrigin(int iEntity, float fResult[3])
{
	if (!IsValidEntity(iEntity))return false;
	SDKCall(g_hCalcAbsolutePosition, iEntity);
	GetEntPropVector(iEntity, Prop_Data, "m_vecAbsOrigin", fResult);
	return (IsValidVector(fResult));
}

float GetEntityDistance(int iEntity, int iTarget, bool bSquared = false)
{
	float fEntityPos[3]; GetEntityAbsOrigin(iEntity, fEntityPos);
	float fTargetPos[3]; GetEntityAbsOrigin(iTarget, fTargetPos);
	return (GetVectorDistance(fEntityPos, fTargetPos, bSquared));
}

stock bool IsValidClient(int iClient) 
{
	return (1 <= iClient <= MaxClients && IsClientInGame(iClient)); 
}

stock bool IsClientSurvivor(int iClient)
{
	return (IsValidClient(iClient) && GetClientTeam(iClient) == 2 && IsPlayerAlive(iClient));
}
//////////////////////////////////////////////////////////////////////////////////////////////

float fCurrentBotPrimaryAmmoPercent;
int iCurrentBotHealth, iCurrentBotTempHealth, iPrimaryWEPID, iSecondaryWEPID;
bool bCurrentBotPrimaryHasLaser;

public Action L4D2_OnFindScavengeItem(int iClient, int &iItem)
{
	int iPrimary = GetPlayerWeaponSlot(iClient, 0);
	iPrimaryWEPID = L4D2Wep_Identify(iPrimary, IDENTIFY_HOLD);	
	
	int iSecondary = GetPlayerWeaponSlot(iClient, 1);
	iSecondaryWEPID = L4D2Wep_Identify(iSecondary, IDENTIFY_HOLD);
	
	bCurrentBotPrimaryHasLaser = false;
	
	if (iPrimaryWEPID != WEPID_NONE)
	{
		bCurrentBotPrimaryHasLaser = (GetEntProp(iPrimary, Prop_Send, "m_upgradeBitVec") & L4D2_WEPUPGFLAG_LASER);
		fCurrentBotPrimaryAmmoPercent = GetAmmoPercent(iPrimary, iClient);
	}
	else
	{
		fCurrentBotPrimaryAmmoPercent = 0;
	}
	
	int iItemWEPID = L4D2Wep_Identify(iItem, IDENTIFY_SAFE);
	
	iCurrentBotHealth = GetClientHealth(iClient);
	iCurrentBotTempHealth = L4D_GetPlayerTempHealth(iClient);
	
	if (iItemWEPID == WEPID_AMMO || iItemWEPID == WEPID_UPGRADE_ITEM)
	{
		return Plugin_Continue;
	}
	
	iItem = GetNearbyUpgrade(iClient);
	if (iItem != -1)
	{
		return Plugin_Changed;
	}
	
	return Plugin_Handled;
}

int GetNearbyUpgrade(int iClient)
{
	float fClientLocation[3];
	GetEntPropVector(iClient, Prop_Data, "m_vecOrigin", fClientLocation);
	
	bool bInCheckpoint = LBI_IsPositionInsideCheckpoint(fClientLocation);

	int iClosestUpgrade = -1;
	float iClosestDistance = 1000.0;
	for (int i = 0; i < g_ScavengeList.Length; i++)
	{
		int iItem = EntRefToEntIndex(g_ScavengeList.Get(i));
		int iItemWEPID = L4D2Wep_Identify(iItem, IDENTIFY_SAFE);
	
		if (iItemWEPID != WEPID_NONE)
		{
			int iItemPriority = GetItemPriority(iItem);
			if (iItemPriority != 999)
			{
				int iItemSlot = L4D2Wep_GetSlotByID(iItemWEPID);
				int iEquipped = GetPlayerWeaponSlot(iClient, iItemSlot);
				int iEquippedPriority = GetItemPriority(iEquipped, iClient);
				
				if (iItemPriority < iEquippedPriority)
				{
					float fItemLocation[3];
					GetEntPropVector(iItem, Prop_Data, "m_vecOrigin", fItemLocation);
					if (bInCheckpoint)
					{
						bool bItemOutsideCheckpoint = !LBI_IsPositionInsideCheckpoint(fItemLocation);
						if (bItemOutsideCheckpoint)
						{
							continue;
						}
					}
				
					float fItemDistance = GetEntityDistance(iClient, iItem);
					
					if (fItemDistance*fItemDistance < iClosestDistance*iClosestDistance)
					{
						iClosestUpgrade = iItem;
						iClosestDistance = fItemDistance;
					}
				}
			}
		}
	}
	
	if (iClosestUpgrade != -1)
	{
		static char sWeaponModel[64];
		
		GetEntityModelname(iClosestUpgrade, sWeaponModel, sizeof(sWeaponModel));
			
		PrintToServer("Found upgrade %s at %f distance", sWeaponModel, iClosestDistance);
	}
	return iClosestUpgrade;
}

void GetEntityModelname(int iEntity, char[] sModelName, int iMaxLength)
{
	GetEntPropString(iEntity, Prop_Data, "m_ModelName", sModelName, iMaxLength);
}

int GetItemPriority(int iItem, int iClient = -1)
{
	int iItemWEPID = L4D2Wep_Identify(iItem, IDENTIFY_ALL);

	if (iItemWEPID == WEPID_NONE)
	{
		return 999;
	}

	int iItemSlot = L4D2Wep_GetSlotByID(iItemWEPID);
	
	switch (iItemSlot)
	{
		case -1: return GetInteractionPriority(iItemWEPID, iItem);
		case 0: return GetPrimaryPriority(iItem, iClient);
		case 1: return GetSecondaryPriority(iItem, iItemWEPID, iClient);
		case 2: return GetGrenadePriority(iItemWEPID, iClient);
		case 3: return GetUtilityPriority(iItemWEPID, iClient);
		case 4: return GetTempHealingPriority(iItemWEPID);
	}
	
	return 999; 
}

int GetInteractionPriority(int iItemWEPID, int iItem)
{
	if (iItemWEPID == WEPID_NONE)
	{
		return 999;
	}

	if (iItemWEPID == WEPID_AMMO && iPrimaryWEPID != WEPID_NONE)
	{
		if (fCurrentBotPrimaryAmmoPercent < 0.6)
		{
			return 1;
		}
	}
	
	if (iItemWEPID == WEPID_UPGRADE_ITEM && !bCurrentBotPrimaryHasLaser && iPrimaryWEPID != WEPID_NONE)
	{
		static char sItemClassname[64];
		GetEntityClassname(iItem, sItemClassname, sizeof(sItemClassname));
		
		if (strcmp(sItemClassname, "upgrade_laser_sight") == 0)
		{
			return 998;
		}
	}
	
	return 999;
}

int GetTempHealingPriority(int iItemWEPID)
{
	if (iItemWEPID == WEPID_NONE)
	{
		return 999;
	}

	switch (iItemWEPID)
	{
		case WEPID_NONE: return 999;
		
		case WEPID_PAIN_PILLS: return 1;
		case WEPID_ADRENALINE: return 2;
	}

	return 999;
}

int GetUtilityPriority(int iItemWEPID, int iClient = -1)
{
	if (iItemWEPID == WEPID_NONE)
	{
		return 999;
	}
	
	int iTeamDefibAmount = GetSurvivorTeamItemCount(WEPID_DEFIBRILLATOR);
	int iTeamHealthAmount = GetSurvivorTeamItemCount(WEPID_FIRST_AID_KIT);
	
	if (iClient != -1)
	{
		if (iItemWEPID == WEPID_DEFIBRILLATOR && iTeamDefibAmount == 1 && iCurrentBotHealth > 40)
		{
			return 1;
		}
		if (iItemWEPID == WEPID_FIRST_AID_KIT && iTeamHealthAmount == 1)
		{
			return 1;
		}
	}
	
	if (iItemWEPID == WEPID_DEFIBRILLATOR && iTeamDefibAmount == 0 && iCurrentBotHealth > 40)
	{
		return 1;
	}
	
	if (iItemWEPID == WEPID_FIRST_AID_KIT && iTeamHealthAmount == 0)
	{
		return 1;
	}
	
	switch (iItemWEPID)
	{
		case WEPID_FIRST_AID_KIT: return 2;
		case WEPID_INCENDIARY_AMMO: return 3;
		case WEPID_FRAG_AMMO: return 4;
		case WEPID_DEFIBRILLATOR: return 5;
	}
	
	return 999;
}

int GetGrenadePriority(int iItemWEPID, int iClient = -1)
{
	if (iItemWEPID == WEPID_NONE)
	{
		return 999;
	}
	
	int iTeamMolotovAmount = GetSurvivorTeamItemCount(WEPID_MOLOTOV);
	int iTeamBileAmount = GetSurvivorTeamItemCount(WEPID_VOMITJAR);
	
	if (iClient != -1)
	{
		if (iItemWEPID == WEPID_MOLOTOV && iTeamMolotovAmount == 1)
		{
			return 1;
		}
		if (iItemWEPID == WEPID_VOMITJAR && iTeamBileAmount == 1)
		{
			return 1;
		}
	}
	
	if (iItemWEPID == WEPID_MOLOTOV && iTeamMolotovAmount == 0)
	{
		return 1;
	}
	
	if (iItemWEPID == WEPID_VOMITJAR && iTeamBileAmount == 0)
	{
		return 1;
	}
	
	switch (iItemWEPID)
	{
		case WEPID_PIPE_BOMB: return 2;
		case WEPID_VOMITJAR: return 3;
		case WEPID_MOLOTOV: return 4;
	}
	
	return 999;
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

int GetSecondaryPriority(int iItem, int iItemWEPID, int iClient = -1)
{
	if (iItemWEPID == WEPID_NONE)
	{
		return 999;
	}
	
	if (fCurrentBotPrimaryAmmoPercent > 0.1)
	{
		if (iItemWEPID == WEPID_MELEE)
		{
			int MeleeID = L4D2Wep_IdentifyMelee(iItem, IDENTIFY_ALL);
			
			switch (MeleeID)
			{
				case MELEEID_MACHETE: return 1;
				case MELEEID_KATANA: return 4;
				case MELEEID_GOLFCLUB: return 5;
				case MELEEID_FIREAXE: return 6;
				case MELEEID_BASEBALL_BAT: return 7;
				case MELEEID_CRICKET_BAT: return 8;
				case MELEEID_ELECTRIC_GUITAR: return 9;
				case MELEEID_TONFA: return 10;
				case MELEEID_CROWBAR: return 11;
			}
			static char sItemmModelname[256];
			GetEntityModelname(iItem, sItemmModelname, sizeof(sItemmModelname));
			
			if (StrContains(sItemmModelname, "machete") != -1)
			{
				return 1;
			}
			if (StrContains(sItemmModelname, "katana") != -1)
			{
				return 4;
			}			
			if (StrContains(sItemmModelname, "golfclub") != -1)
			{
				return 5;
			}	
			if (StrContains(sItemmModelname, "fireaxe") != -1)
			{
				return 6;
			}
			if (StrContains(sItemmModelname, "baseball_bat") != -1)
			{
				return 7;
			}
			if (StrContains(sItemmModelname, "cricket_bat") != -1)
			{
				return 8;
			}
			if (StrContains(sItemmModelname, "electric_guitar") != -1)
			{
				return 9;
			}
			if (StrContains(sItemmModelname, "tonfa") != -1)
			{
				return 10;
			}
			if (StrContains(sItemmModelname, "crowbar") != -1)
			{
				return 11;
			}
		}
		
		switch (iItemWEPID)
		{
			case WEPID_PISTOL_MAGNUM: return 1;
			case WEPID_CHAINSAW: return 3;
		}
		
		if (iItemWEPID == WEPID_PISTOL)
		{
			if (iClient != -1)
			{
				static char sItemmModelname[256];
				GetEntityModelname(iItem, sItemmModelname, sizeof(sItemmModelname));
				
				if (StrContains(sItemmModelname, "dual") != -1)
				{
					return 12;
				}
				else
				{
					return 13;
				}
			}
			else
			{
				return 12;
			}
		}
	}
	else
	{
		if (iItemWEPID == WEPID_PISTOL_MAGNUM)
		{
			return 2;
		}
		
		if (iItemWEPID == WEPID_PISTOL)
		{
			if (iClient != -1)
			{
				static char sItemmModelname[256];
				GetEntityModelname(iItem, sItemmModelname, sizeof(sItemmModelname));
				
				if (StrContains(sItemmModelname, "dual") != -1)
				{
					return 2;
				}
				else
				{
					return 3;
				}
			}
			else
			{
				return 2;
			}
		}
	}
	
	return 999;
}

int GetPrimaryPriority(int iItem, int iClient = -1)
{
	int iItemWEPID = L4D2Wep_Identify(iItem, IDENTIFY_ALL);

	if (iItemWEPID == WEPID_NONE)
	{
		return 999;
	}

	float iAmmoPercent = GetAmmoPercent(iItem, iClient);
	if (iAmmoPercent <= 0)
	{
		return 999;
	}
	
	if (iSecondaryWEPID == WEPID_MELEE || iSecondaryWEPID == WEPID_CHAINSAW)
	{
		switch (iItemWEPID)
		{
			case WEPID_RIFLE_DESERT: return 1;
			case WEPID_RIFLE_AK47: return 2;
			case WEPID_RIFLE: return 3;
			case WEPID_SHOTGUN_SPAS: return 4;
			case WEPID_AUTOSHOTGUN: return 5;
		}
	}
	else
	{
		switch (iItemWEPID)
		{
			case WEPID_SHOTGUN_SPAS: return 1;
			case WEPID_AUTOSHOTGUN: return 2;
			case WEPID_RIFLE_DESERT: return 3;
			case WEPID_RIFLE_AK47: return 4;
			case WEPID_RIFLE: return 5;
			case WEPID_SNIPER_MILITARY: return 6;
			case WEPID_HUNTING_RIFLE: return 7;
			case WEPID_SMG_SILENCED: return 8;
			case WEPID_SMG_MP5: return 9;
			case WEPID_SHOTGUN_CHROME: return 10;
			case WEPID_PUMPSHOTGUN: return 11;
			case WEPID_SMG: return 12;
			case WEPID_RIFLE_SG552: return 13;
		}
	}
	
	return 999;
}

float GetAmmoPercent(int iWeapon, int iClient = -1)
{
	int iWeaponWEPID = L4D2Wep_Identify(iWeapon, IDENTIFY_ALL);
	
	if (iWeaponWEPID == WEPID_NONE)
	{
		PrintToServer("No valid WeaponID");
		return 0.0;
	}

	int iWeaponAmmoID = L4D2Wep_WepIDToAmmoID(iWeaponWEPID);
	
	if (iWeaponAmmoID == AMMOID_NONE)
	{
		PrintToServer("No valid AmmoID");
		return 0.0;
	}
	
	float iWeaponMaxAmmo = L4D2Wep_GetAmmo(iWeaponAmmoID);

	if (iClient != -1)
	{	
		int iWeaponAmmoType = GetEntProp(iWeapon, Prop_Send, "m_iPrimaryAmmoType");
		float iWeaponAmmo = GetEntProp(iClient, Prop_Send, "m_iAmmo", 4, iWeaponAmmoType);
		
		if (iWeaponAmmo <= 0.0)
		{
			return 0.0;
		}
		
		return iWeaponAmmo / iWeaponMaxAmmo;
	}
	else
	{
		iWeaponWEPID = L4D2Wep_Identify(iWeapon, IDENTIFY_SPAWN);
		if (iWeaponWEPID != WEPID_NONE)
		{
			return 1.0;
		}
		
		iWeaponWEPID = L4D2Wep_Identify(iWeapon, IDENTIFY_SINGLE);
		if (iWeaponWEPID != WEPID_NONE)
		{
			float iWeaponAmmo = GetEntProp(iWeapon, Prop_Data, "m_iExtraPrimaryAmmo");
			
			if (iWeaponAmmo <= 0.0)
			{
				return 0.0;
			}
			
			return iWeaponAmmo / iWeaponMaxAmmo;
		}
	}
	
	return 0.0;
}