# Team Balance & Swap Commands

A SourceMod plugin for CS:GO that provides team balance functionality and player-controlled team switching commands.

## Features

- Queue team changes that execute at round start
- Automatic team balancing system
- Cooldown system to prevent abuse
- Team imbalance protection
- Immunity for newly joined players
- Prevents switching while alive (configurable)

## Commands

### Player Commands

- `!joinct` - Queue switch to Counter-Terrorists
- `!joint` - Queue switch to Terrorists
- `!joinspec` - Queue switch to Spectators
- `!cancel` - Cancel pending team swap

## Configuration

Maximum allowed team difference (default: 5)
```
sm_teamswap_maxdiff 5
```

Minimum players required for balance checks (default: 4)
```
sm_teamswap_minplayers 4
```

Block team switching during warmup (0 = disabled, 1 = enabled)
```
sm_teamswap_blockwarmup 0
```

Enable automatic team balancing at round start (0 = disabled, 1 = enabled)
```
sm_teambalance_enable 1
```

Cooldown between !joint/!joinct commands in seconds (default: 180)
```
sm_teamswap_cmd_cooldown 180.0
```

Cooldown between manual team changes via menu in seconds (default: 60)
```
sm_teamswap_manual_cooldown 60.0
```

Immunity from auto-balance for newly joined players in seconds (default: 60)
```
sm_teambalance_join_immunity 60.0
```

## How It Works

### Team Swapping

Players use commands to queue a team change. The switch executes at the start of the next round to avoid disrupting gameplay. Players cannot switch while alive unless moving to spectator.

### Auto-Balance

When enabled, the plugin automatically balances teams at round start if the difference exceeds 1 player. It prioritizes moving dead players first, then alive players if necessary. Recently balanced players and newly joined players are temporarily immune.

### Cooldowns

Two separate cooldown systems prevent abuse:
- Command cooldown applies to !joint/!joinct/!joinspec
- Manual cooldown applies to team menu switches

Prevents players from joining teams if it would create an imbalance greater than the configured maximum difference.

## Technical Details

- Automatically disables `mp_autoteambalance` to prevent conflicts
- Hooks damage events to protect players during team switches
- Tracks team change history for intelligent balancing
- Comprehensive logging for debugging and monitoring

## Requirements

- SourceMod 1.10 or later

## Installation

1. Copy the compiled .smx file to `addons/sourcemod/plugins/` (compiled on windows)
2. Restart the server or type `sm plugins load swapcommands` in console
3. Configure settings in `cfg/sourcemod/swapcommands.cfg`

## Support

For issues or questions, visit https://www.alyx.ro/