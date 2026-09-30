-- STAND DOS CINTOE'S -- run this on every stand (alt) account, not on your main.
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
