#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PREFIX " \x0ETEAM"
#define COLOR_PRIMARY "\x0E"
#define COLOR_SECONDARY "\x08"
#define SEPARATOR "▪"

bool g_bPendingSwap[MAXPLAYERS + 1];
int g_iTargetTeam[MAXPLAYERS + 1];
int g_iPreviousTeam[MAXPLAYERS + 1];
bool g_bSwitchingTeam[MAXPLAYERS + 1];
bool g_bInRoundPrestart = false;
float g_fLastManualTeamChange[MAXPLAYERS + 1];
float g_fLastSwapCommand[MAXPLAYERS + 1];
bool g_bWasAutoBalanced[MAXPLAYERS + 1];
float g_fJoinTime[MAXPLAYERS + 1];

ConVar g_cvMaxTeamDifference;
ConVar g_cvMinPlayersForBalance;
ConVar g_cvBlockWarmupSwitch;
ConVar g_cvAutoBalance;
ConVar g_cvCmdCooldown;
ConVar g_cvBalanceJoinImmunity;

public Plugin myinfo =
{
    name = "[Alyx-Network] Team Balance & Swap Commands",
    author = "dragos112",
    description = "Team balance system with swap commands. !joinct / !joint / !joinspec",
    version = "3.2.5",
    url = "https://www.alyx.ro/"
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_joinct", JoinCT);
    RegConsoleCmd("sm_joint", JoinT);
    RegConsoleCmd("sm_joinspec", JoinSpec);
    RegConsoleCmd("sm_cancel", CancelSwap);

    AddCommandListener(Command_JoinTeam, "jointeam");

    HookEvent("round_prestart", Event_RoundPrestart);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);

    g_cvMaxTeamDifference = CreateConVar("sm_teamswap_maxdiff", "5", "Maximum allowed team difference", _, true, 1.0);
    g_cvMinPlayersForBalance = CreateConVar("sm_teamswap_minplayers", "4", "Minimum players required for team balance check", _, true, 2.0);
    g_cvBlockWarmupSwitch = CreateConVar("sm_teamswap_blockwarmup", "0", "Block team switching during warmup", _, true, 0.0, true, 1.0);
    g_cvAutoBalance = CreateConVar("sm_teambalance_enable", "1", "Enable automatic team balancing at round start", _, true, 0.0, true, 1.0);

    g_cvCmdCooldown = CreateConVar("sm_teamswap_cmd_cooldown", "180.0", "Cooldown between !joint/!joinct commands (in seconds)", _, true, 0.0);
    g_cvBalanceJoinImmunity = CreateConVar("sm_teambalance_join_immunity", "60.0", "Immunity from auto-balance for newly joined players (seconds)", _, true, 0.0);

    AutoExecConfig(true, "swapcommands");
    HookConVarChange(FindConVar("mp_autoteambalance"), OnAutoTeamBalanceChanged);
}

public void OnAutoTeamBalanceChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar.IntValue != 0)
        convar.IntValue = 0;
}

public void OnMapStart()
{
    g_bInRoundPrestart = false;

    ConVar mp_autoteambalance = FindConVar("mp_autoteambalance");
    if (mp_autoteambalance != null)
        mp_autoteambalance.IntValue = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_bPendingSwap[i] = false;
        g_iTargetTeam[i] = 0;
        g_iPreviousTeam[i] = 0;
        g_bSwitchingTeam[i] = false;
        g_fLastManualTeamChange[i] = 0.0;
        g_fLastSwapCommand[i] = 0.0;
        g_bWasAutoBalanced[i] = false;
    }
}

public void OnClientDisconnect(int client)
{
    g_bPendingSwap[client] = false;
    g_iTargetTeam[client] = 0;
    g_iPreviousTeam[client] = 0;
    g_bSwitchingTeam[client] = false;
    g_fLastManualTeamChange[client] = 0.0;
    g_fLastSwapCommand[client] = 0.0;
    g_bWasAutoBalanced[client] = false;
}

public void OnClientPutInServer(int client)
{
    if (IsValidClient(client))
    {
        g_iPreviousTeam[client] = GetClientTeam(client);
        g_fLastManualTeamChange[client] = 0.0;
        g_fLastSwapCommand[client] = 0.0;
        g_bWasAutoBalanced[client] = false;
        g_fJoinTime[client] = GetGameTime();
        SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    }
}

public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (IsValidClient(victim) && g_bSwitchingTeam[victim])
        return Plugin_Handled;

    return Plugin_Continue;
}

void FormatTimeString(float seconds, char[] buffer, int bufferSize)
{
    int minutes = RoundToFloor(seconds / 60.0);
    int secs = RoundToFloor(seconds - (minutes * 60.0));

    if (minutes > 0)
    {
        if (secs > 0)
            Format(buffer, bufferSize, "%s%d minute%s and %d second%s%s", COLOR_PRIMARY, minutes, minutes == 1 ? "" : "s", secs, secs == 1 ? "" : "s", COLOR_SECONDARY);
        else
            Format(buffer, bufferSize, "%d minute%s", minutes, minutes == 1 ? "" : "s");
    }
    else
    {
        Format(buffer, bufferSize, "%d second%s", secs, secs == 1 ? "" : "s");
    }
}

void Message(int client, const char[] format, any...)
{
    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 3);
    PrintToChat(client, "%s %s%s %s", PREFIX, COLOR_SECONDARY, SEPARATOR, buffer);
}

bool CanPlayerSwitch(int client, int targetTeam, bool bypassCooldown = false, bool checkAlive = true, bool checkImbalance = true)
{
    if (!IsValidClient(client))
        return false;

    if (!bypassCooldown)
    {
        float cooldown = g_cvCmdCooldown.FloatValue;
        if (g_fLastSwapCommand[client] > 0.0 && GetGameTime() - g_fLastSwapCommand[client] < cooldown)
        {
            float remainingTime = cooldown - (GetGameTime() - g_fLastSwapCommand[client]);
            char timeStr[64];
            FormatTimeString(remainingTime, timeStr, sizeof(timeStr));
            Message(client, "Please wait %s%s%s before using swap commands again.", COLOR_PRIMARY, timeStr, COLOR_SECONDARY);
            return false;
        }
    }

    if (GetClientTeam(client) == targetTeam)
    {
        Message(client, "You are %salready%s in this team!", COLOR_PRIMARY, COLOR_SECONDARY);
        return false;
    }

    if (checkAlive && IsPlayerAlive(client) && targetTeam != CS_TEAM_SPECTATOR)
    {
        Message(client, "You can not switch your team while you are %salive%s!", COLOR_PRIMARY, COLOR_SECONDARY);
        return false;
    }

    if (g_cvBlockWarmupSwitch.BoolValue && GameRules_GetProp("m_bWarmupPeriod") == 1)
    {
        Message(client, "Team switching is %sdisabled%s during %swarmup%s!", COLOR_PRIMARY, COLOR_SECONDARY, COLOR_PRIMARY, COLOR_SECONDARY);
        return false;
    }

    if (checkImbalance && targetTeam != CS_TEAM_SPECTATOR)
    {
        int ctCount = GetTeamClientCount(CS_TEAM_CT);
        int tCount = GetTeamClientCount(CS_TEAM_T);
        int totalPlayers = ctCount + tCount;

        if (totalPlayers >= g_cvMinPlayersForBalance.IntValue)
        {
            int maxDiff = g_cvMaxTeamDifference.IntValue;
            if (targetTeam == CS_TEAM_CT && (ctCount + 1) - tCount > maxDiff)
            {
                Message(client, "Cannot join %sCounter-Terrorists%s team due to imbalance (more than %d players difference).", COLOR_PRIMARY, COLOR_SECONDARY, maxDiff);
                return false;
            }
            else if (targetTeam == CS_TEAM_T && (tCount + 1) - ctCount > maxDiff)
            {
                Message(client, "Cannot join %sTerrorists%s team due to imbalance (more than %d players difference).", COLOR_PRIMARY, COLOR_SECONDARY, maxDiff);
                return false;
            }
        }
    }

    return true;
}

public Action JoinCT(int client, int args)
{
    if (!CanPlayerSwitch(client, CS_TEAM_CT, false, false, false))
        return Plugin_Handled;

    g_bPendingSwap[client] = true;
    g_iTargetTeam[client] = CS_TEAM_CT;
    g_fLastSwapCommand[client] = GetGameTime();

    char auth[32];
    GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
    LogMessage("Player %L (%s) queued swap to CT", client, auth);

    Message(client, "You will be switched to %sCounter-Terrorists%s at the start of next round.", COLOR_PRIMARY, COLOR_SECONDARY);
    return Plugin_Handled;
}

public Action JoinT(int client, int args)
{
    if (!CanPlayerSwitch(client, CS_TEAM_T, false, false, false))
        return Plugin_Handled;

    g_bPendingSwap[client] = true;
    g_iTargetTeam[client] = CS_TEAM_T;
    g_fLastSwapCommand[client] = GetGameTime();

    char auth[32];
    GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
    LogMessage("Player %L (%s) queued swap to T", client, auth);

    Message(client, "You will be switched to %sTerrorists%s at the start of next round.", COLOR_PRIMARY, COLOR_SECONDARY);
    return Plugin_Handled;
}

public Action JoinSpec(int client, int args)
{
    if (!CanPlayerSwitch(client, CS_TEAM_SPECTATOR, false, false, false))
        return Plugin_Handled;

    g_bPendingSwap[client] = true;
    g_iTargetTeam[client] = CS_TEAM_SPECTATOR;
    g_fLastSwapCommand[client] = GetGameTime();

    char auth[32];
    GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
    LogMessage("Player %L (%s) queued swap to Spectator", client, auth);

    Message(client, "You will be moved to %sSpectators%s at the start of next round.", COLOR_PRIMARY, COLOR_SECONDARY);
    return Plugin_Handled;
}

public Action CancelSwap(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    if (!g_bPendingSwap[client])
    {
        Message(client, "You don't have a pending team swap.");
        return Plugin_Handled;
    }

    g_bPendingSwap[client] = false;
    g_iTargetTeam[client] = 0;

    char auth[32];
    GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
    LogMessage("Player %L (%s) cancelled pending swap", client, auth);

    Message(client, "Your pending team swap has been %scancelled%s.", COLOR_PRIMARY, COLOR_SECONDARY);
    return Plugin_Handled;
}

public Action Command_JoinTeam(int client, const char[] command, int argc)
{
    if (!IsValidClient(client))
        return Plugin_Continue;

    if (argc < 1)
        return Plugin_Continue;

    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    int targetTeam = StringToInt(arg);
    int currentTeam = GetClientTeam(client);

    if (currentTeam == targetTeam)
    {
        Message(client, "You are %salready%s in this team!", COLOR_PRIMARY, COLOR_SECONDARY);
        return Plugin_Stop;
    }

    if (IsPlayerAlive(client) && targetTeam != CS_TEAM_SPECTATOR && currentTeam != CS_TEAM_SPECTATOR)
    {
        Message(client, "You can not switch your team while you are %salive%s!", COLOR_PRIMARY, COLOR_SECONDARY);
        return Plugin_Stop;
    }

    if (g_bPendingSwap[client])
    {
        Message(client, "You have a pending team swap. Use %s!cancel%s to cancel it first.", COLOR_PRIMARY, COLOR_SECONDARY);
        return Plugin_Stop;
    }

    if (targetTeam != CS_TEAM_SPECTATOR)
    {
        int ctCount = GetTeamClientCount(CS_TEAM_CT);
        int tCount = GetTeamClientCount(CS_TEAM_T);
        int totalPlayers = ctCount + tCount;

        if (totalPlayers >= g_cvMinPlayersForBalance.IntValue)
        {
            int maxDiff = g_cvMaxTeamDifference.IntValue;
            if (targetTeam == CS_TEAM_CT && (ctCount + 1) - tCount > maxDiff)
            {
                Message(client, "Cannot join %sCounter-Terrorists%s team due to imbalance (more than %d players difference).", COLOR_PRIMARY, COLOR_SECONDARY, maxDiff);
                return Plugin_Stop;
            }
            else if (targetTeam == CS_TEAM_T && (tCount + 1) - ctCount > maxDiff)
            {
                Message(client, "Cannot join %sTerrorists%s team due to imbalance (more than %d players difference).", COLOR_PRIMARY, COLOR_SECONDARY, maxDiff);
                return Plugin_Stop;
            }
        }
    }

    return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return Plugin_Continue;

    int oldTeam = event.GetInt("oldteam");
    int newTeam = event.GetInt("team");
    bool disconnect = event.GetBool("disconnect");

    if (disconnect)
        return Plugin_Continue;

    if (oldTeam == newTeam)
        return Plugin_Continue;

    if (g_bSwitchingTeam[client] || g_bPendingSwap[client])
    {
        g_iPreviousTeam[client] = oldTeam;
        return Plugin_Continue;
    }

    if (IsPlayerAlive(client) && newTeam != CS_TEAM_SPECTATOR && oldTeam != CS_TEAM_SPECTATOR)
    {
        if (g_bInRoundPrestart)
        {
            g_iPreviousTeam[client] = newTeam;
            return Plugin_Continue;
        }

        g_iPreviousTeam[client] = oldTeam;
        event.SetInt("team", oldTeam);
        CreateTimer(0.1, Timer_RestoreTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        Message(client, "You can not switch your team while you are %salive%s!", COLOR_PRIMARY, COLOR_SECONDARY);
        return Plugin_Changed;
    }

    g_iPreviousTeam[client] = oldTeam;

    if (!(g_bSwitchingTeam[client] || g_bPendingSwap[client] || g_bInRoundPrestart))
    {
        g_bWasAutoBalanced[client] = false;

        char auth[32];
        GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
        LogMessage("Player %L (%s) manually changed from team %d to %d", client, auth, oldTeam, newTeam);
    }

    return Plugin_Continue;
}

public Action Timer_RestoreTeam(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client))
    {
        int previousTeam = g_iPreviousTeam[client];
        if (previousTeam > 0 && GetClientTeam(client) != previousTeam)
            ChangeClientTeam(client, previousTeam);
    }

    return Plugin_Stop;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    return Plugin_Continue;
}

void PerformTeamBalance()
{
    if (!g_cvAutoBalance.BoolValue)
        return;

    int ctCount = GetTeamClientCount(CS_TEAM_CT);
    int tCount = GetTeamClientCount(CS_TEAM_T);
    int totalPlayers = ctCount + tCount;

    if (totalPlayers < g_cvMinPlayersForBalance.IntValue)
        return;

    if (ctCount == tCount || ctCount + 1 == tCount || ctCount == tCount + 1)
        return;

    int playersToMove = 0;
    int fromTeam, toTeam;

    if (ctCount > tCount + 1)
    {
        playersToMove = (ctCount - tCount) / 2;
        fromTeam = CS_TEAM_CT;
        toTeam = CS_TEAM_T;
    }
    else if (tCount > ctCount + 1)
    {
        playersToMove = (tCount - ctCount) / 2;
        fromTeam = CS_TEAM_T;
        toTeam = CS_TEAM_CT;
    }

    if (playersToMove <= 0)
        return;

    LogMessage("Auto-balance: CT=%d, T=%d, need to move %d players from %s to %s",
               ctCount, tCount, playersToMove,
               fromTeam == CS_TEAM_CT ? "CT" : "T",
               toTeam == CS_TEAM_CT ? "CT" : "T");

    ArrayList deadPlayers = new ArrayList();
    ArrayList alivePlayers = new ArrayList();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client) || GetClientTeam(client) != fromTeam)
            continue;

        if (g_bSwitchingTeam[client] || g_bPendingSwap[client])
            continue;

        if (g_bWasAutoBalanced[client])
            continue;

        float joinImmunity = g_cvBalanceJoinImmunity.FloatValue;
        if (joinImmunity > 0.0 && GetGameTime() - g_fJoinTime[client] < joinImmunity)
            continue;

        if (IsPlayerAlive(client))
            alivePlayers.Push(client);
        else
            deadPlayers.Push(client);
    }

    int moved = 0;

    for (int i = 0; i < deadPlayers.Length && moved < playersToMove; i++)
    {
        int client = deadPlayers.Get(i);
        if (IsValidClient(client) && GetClientTeam(client) == fromTeam)
        {
            CS_SwitchTeam(client, toTeam);
            g_bWasAutoBalanced[client] = true;
            CreateTimer(30.0, Timer_ClearAutoBalanceFlag, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
            moved++;

            char auth[32];
            GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
            LogMessage("Auto-balanced player %L (%s) from %s to %s (dead)",
                       client, auth,
                       fromTeam == CS_TEAM_CT ? "CT" : "T",
                       toTeam == CS_TEAM_CT ? "CT" : "T");
        }
    }

    for (int i = 0; i < alivePlayers.Length && moved < playersToMove; i++)
    {
        int client = alivePlayers.Get(i);
        if (IsValidClient(client) && GetClientTeam(client) == fromTeam)
        {
            CS_SwitchTeam(client, toTeam);
            g_bWasAutoBalanced[client] = true;
            CreateTimer(30.0, Timer_ClearAutoBalanceFlag, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
            moved++;

            char auth[32];
            GetClientAuthId(client, AuthId_SteamID64, auth, sizeof(auth));
            LogMessage("Auto-balanced player %L (%s) from %s to %s (alive)",
                       client, auth,
                       fromTeam == CS_TEAM_CT ? "CT" : "T",
                       toTeam == CS_TEAM_CT ? "CT" : "T");
        }
    }

    delete deadPlayers;
    delete alivePlayers;
}

public void Event_RoundPrestart(Event event, const char[] name, bool dontBroadcast)
{
    g_bInRoundPrestart = true;

    for (int i = 1; i <= MaxClients; i++)
        if (g_bPendingSwap[i] && IsValidClient(i))
        {
            int currentTeam = GetClientTeam(i);

            if (currentTeam == g_iTargetTeam[i])
            {
                Message(i, "You are already in the requested team.");
                g_bPendingSwap[i] = false;
                g_iTargetTeam[i] = 0;
                continue;
            }

            if (CanPlayerSwitch(i, g_iTargetTeam[i], true, false, false))
            {
                g_bSwitchingTeam[i] = true;
                bool wasAlive = IsPlayerAlive(i);

                ChangeTeam(i, g_iTargetTeam[i]);

                char auth[32];
                GetClientAuthId(i, AuthId_SteamID64, auth, sizeof(auth));
                LogMessage("Executed queued swap for player %L (%s) to team %d",
                           i, auth, g_iTargetTeam[i]);

                if (g_iTargetTeam[i] != CS_TEAM_SPECTATOR)
                {
                    if (wasAlive)
                        CreateTimer(0.2, Timer_RespawnPlayer, GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
                    else
                        CreateTimer(0.1, Timer_RespawnPlayer, GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
                }

                switch (g_iTargetTeam[i])
                {
                    case CS_TEAM_CT:
                        Message(i, "You have been switched to the %sCounter-Terrorists%s team.", COLOR_PRIMARY, COLOR_SECONDARY);
                    case CS_TEAM_T:
                        Message(i, "You have been switched to the %sTerrorists%s team.", COLOR_PRIMARY, COLOR_SECONDARY);
                    case CS_TEAM_SPECTATOR:
                        Message(i, "You have been moved to %sSpectators%s.", COLOR_PRIMARY, COLOR_SECONDARY);
                }
            }

            g_bPendingSwap[i] = false;
            g_iTargetTeam[i] = 0;

            CreateTimer(5.0, Timer_ClearSwitchingFlag, GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
        }

    if (g_cvAutoBalance.BoolValue)
        PerformTeamBalance();

    CreateTimer(2.0, Timer_ClearRoundPrestartFlag, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RespawnPlayer(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client) && GetClientTeam(client) != CS_TEAM_SPECTATOR && !IsPlayerAlive(client))
        CS_RespawnPlayer(client);

    return Plugin_Stop;
}

public Action Timer_ClearSwitchingFlag(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client))
        g_bSwitchingTeam[client] = false;

    return Plugin_Stop;
}

public Action Timer_ClearAutoBalanceFlag(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client))
        g_bWasAutoBalanced[client] = false;

    return Plugin_Stop;
}

public Action Timer_ClearRoundPrestartFlag(Handle timer)
{
    g_bInRoundPrestart = false;
    return Plugin_Stop;
}

void ChangeTeam(int client, int team)
{
    int old = GetEntProp(client, Prop_Send, "m_lifeState");
    SetEntProp(client, Prop_Send, "m_lifeState", 2);

    ChangeClientTeam(client, team);
    SetEntProp(client, Prop_Send, "m_lifeState", old);
}

bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client);
}
