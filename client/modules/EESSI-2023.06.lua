-- EESSI modulefile
-- Provides access to the EESSI software stack

local version = "2023.06"  -- Can be parameterized if needed

help([[
EESSI: European Environment for Scientific Software Installations
This module provides access to the EESSI software stack via CVMFS.

Version: ]] .. version .. [[

After loading this module, you'll have access to scientific software
provided by the EESSI project through the module system.

For more information, visit: https://www.eessi.io/
]])

whatis("Name: EESSI")
whatis("Version: " .. version)
whatis("Description: European Environment for Scientific Software Installations")
whatis("URL: https://www.eessi.io/")

-- Function to execute when module is loaded
local shell = myShellType()

if (shell == "bash" or shell == "zsh" or shell == "sh") then
    -- For bash/zsh/sh shells
    cmd = "source /cvmfs/software.eessi.io/versions/" .. version .. "/init/lmod/bash"
    execute{cmd=cmd, modeA={"load"}}
    
    -- Display informational message
    LmodMessage("EESSI " .. version .. " has been loaded.")
    LmodMessage("The EESSI software stack is now available through the module system.")
    LmodMessage("For available modules, type: module avail")
elseif (shell == "csh" or shell == "tcsh") then
    -- For csh/tcsh shells
    cmd = "source /cvmfs/software.eessi.io/versions/" .. version .. "/init/lmod/csh"
    execute{cmd=cmd, modeA={"load"}}
    
    -- Display informational message
    LmodMessage("EESSI " .. version .. " has been loaded.")
    LmodMessage("The EESSI software stack is now available through the module system.")
    LmodMessage("For available modules, type: module avail")
else
    -- Fallback for other shells
    LmodError("Unsupported shell type: " .. shell)
end
