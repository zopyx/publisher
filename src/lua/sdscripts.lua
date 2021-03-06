--
--  sdscripts.lua
--  speedata publisher
--
--  Copyright 2010-2011 Patrick Gundlach.
--  See file COPYING in the root directory for license info.
--


dofile(arg[1])

function get_ps_name( dateiname )
  local info = fontloader.info(dateiname)
  return info.fontname
end

local cmd = arg[2]

if cmd=="list-fonts" then
  local is_xml = arg[3]=="xml"
  texio.write_nl("\n")
  if is_xml then
  
  else
    texio.write_nl(string.format("%-40s %s","Dateiname","PostScript Name"))
    texio.write_nl(string.format("%-40s %s","-----------------------------------","---------------"))
  end
  local l
  local dateinamen_sortiert = {}
  for filename,_ in pairs(kpse.filelist) do
    l = filename:lower()
    if l:match("%.pfb$") or l:match("%.ttf$") or l:match("%.otf") then
      dateinamen_sortiert[#dateinamen_sortiert + 1] = filename
    end
  end
  table.sort(dateinamen_sortiert)
  local psname
  for i,v in ipairs(dateinamen_sortiert) do
    psname = get_ps_name(kpse.filelist[v])
    if is_xml then
      print(string.format('<LadeSchriftdatei name="%s" dateiname="%s" />',psname,v))
    else
      texio.write_nl(string.format("%-40s %s",v,psname))
    end
  end
  texio.write_nl("----------------------------\n")
  for i,v in ipairs(dateinamen_sortiert) do
    psname = get_ps_name(kpse.filelist[v])
    if is_xml then
      print(string.format('<LoadFontfile name="%s" filename="%s" />',psname,v))
    else
      texio.write_nl(string.format("%-40s %s",v,psname))
    end
  end
  texio.write_nl("")
end