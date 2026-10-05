-- iMac14,4 (Mid 2014) speakers: prefer the 4-channel profile on the built-in
-- card, so the "iMac Speakers" filter (60-imac-speakers.conf) has its output.
--
-- Installed system-wide by scripts/install-fix.sh --system to
--   /etc/wireplumber/main.lua.d/51-imac-speakers.lua
-- A profile a user picks themselves in Sound settings still wins.

table.insert(device_defaults.profile_priorities, {
  matches = {
    {
      { "device.name", "equals", "@CARD@" },
    },
  },
  -- lower index = higher priority
  priorities = {
    "output:analog-surround-40+input:analog-stereo",
    "output:analog-surround-40",
  },
})
