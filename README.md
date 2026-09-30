# STAND DOS CINTOE'S

A stand squad for The Strongest Battlegrounds. Load it on up to four alt
accounts in the same server as your main. They float beside you, hunt whoever
you name, and take their orders from your chat.

## Load it

Run this on every stand account, not on your main. The same lines are in
[loader.lua](loader.lua).

```lua
_G.HOST_USERNAME     = "YourMainAccount" -- your main account (wrong capitals or a display name still work)
_G.PREFIX            = "."      -- chat command prefix
_G.MESSAGES          = false    -- stands talk in chat
_G.GUI               = false    -- open the console at load (.gui opens it any time)
_G.BLACK_SCREEN      = true     -- black stats screen + 3D off on the alt (F6 or .black toggles it)
_G.HUNT_DISTANCE     = 6.1      -- studs from the prey (.dist 5 changes it live)
_G.HUNT_FROM         = "Behind" -- a lone stand hunts from here; two go right + left
_G.MAX_STANDS        = 4        -- stands on one prey at once; extras wait as backup
_G.YIELD             = true     -- step into the void while a squadmate is in a locked move
_G.HUNT_WITHOUT_HOST = true     -- keep hunting when the host dies or leaves
_G.FOLLOW_SPEED      = 1        -- 1 = snaps beside you, lower = smoother
_G.OFFSET_RIGHT      = 3        -- idle spot beside you
_G.OFFSET_UP         = 2.5
_G.OFFSET_BACK       = 4
_G.ASSETS            = "https://raw.githubusercontent.com/Mrzaytoon/stand-dos-cintoes/main/StandDosCintoes/"
loadstring(game:HttpGet("https://raw.githubusercontent.com/Mrzaytoon/stand-dos-cintoes/main/Stand-dos-Cintoes.lua"))()
```

Every line above the loadstring is optional. Leave one out and the stand keeps
the value it saved last time.

## Commands

Typed in chat by the host.

| Command | What it does |
|---|---|
| `.s` | summon the stands beside you |
| `.d` | hide them in the void under you |
| `.a name` | hunt that player until `.stop` (nearest to you if blank) |
| `.v name` | hunt them and carry them under the kill plane, on a loop |
| `.b name` | grab that player and carry them to you |
| `.stop` | stop and come back |
| `.1` `.2` `.3` `.4` | use that skill now |
| `.m1` | punch barrage in front of you; again to stop |
| `.dash` | dash spam on or off |
| `.ult` | awaken when the bar is full |
| `.dist 5` | how far they keep from the prey, in studs (6.1 is the measured M1 reach) |
| `.angle behind` | the angle a lone stand strikes from (`left flank`, `in front`, `above`, ...) |
| `.pose right` | where they wait beside you (`left`, `behind`, `above`) |
| `.auto` | the stands find each other and take a slot each |
| `.fan ring` | spread all the way round the prey, or `arc` to stay near one angle |
| `.squad a, b` | name the other stands by hand; blank clears it |
| `.say text` | make the stand talk |
| `.gui` | open or close the console on the stand's own screen |
| `.black` | the alt screen on or off (`.black on`, `.black off`) |
| `.cmds` | list the commands in chat |

On a stand's own window: **F6** toggles the alt screen, **Backspace** frees the
stand, **Right Ctrl** shows or hides the console.

## The alt screen

On an alt the window goes black and Roblox stops drawing the 3D world, while
the stand keeps fighting exactly as before. It shows the stand's name, what it
is doing, the host, kills, health, squad slot, FPS and ping. Measured on one
alt mid-fight: GPU use 19.8% down to 5.3%, CPU 15.0% down to 10.8%.
`_G.BLACK_SCREEN = false` keeps the normal view.

## Credits

Fonts: Figtree (Copyright 2022 The Figtree Project Authors) and Syne
(Copyright 2019 The Syne Project Authors), both under the SIL Open Font
License 1.1. Icons: [Lucide](https://lucide.dev), ISC License.
