--- Here goes everything that does not belong anywhere else. Other parts are font handling, the command
--- list, page and gridsetup, debugging and initialization. We start with the function `dothings()` that
--- initializes some variables and starts processing (`dispatch())
-- 
--  publisher.lua
--  speedata publisher
--
--  Copyright 2010-2012 Patrick Gundlach.
--  See file COPYING in the root directory for license info.

file_start("publisher.lua")

barcodes = do_luafile("barcodes.lua")
local luxor = do_luafile("luxor.lua")
local commands     = require("publisher.commands")
local seite        = require("publisher.page")
local translations = require("translations")
local fontloader   = require("fonts.fontloader")
local paragraph    = require("paragraph")
local fonts        = require("publisher.fonts")


sd_xpath_funktionen      = require("publisher.layout_functions")
orig_xpath_funktionen    = require("publisher.xpath_functions")



module(...,package.seeall)

--- One big point (DTP point, PostScript point) is approx. 65781 scaled points.
factor = 65781 

--- We use a lot of attributes to delay the processing of font shapes, ... to
--- a later time. These attributes have have any number, they just need to be
--- constant across the whole source.
att_fontfamily     = 1
att_italic         = 2
att_bold           = 3
att_script         = 4
att_underline      = 5

--- These attributes are for image shifting. The amount of shift up/left can
--- be negative and is counted in scaled points.
att_shift_left     = 100
att_shift_up       = 101

--- A tie glue (U+00A0) is a non-breaking space
att_tie_glue       = 201

--- These attributes are used in tabular material
att_space_prio     = 300
att_space_amount   = 301

att_break_below    = 400
att_break_above    = 401

--- `att_is_table_row` is used in `tabular.lua` and if set to 1, it denotes
--- a regular table row, and not a spacer. Spacers must not appear
--- at the top or the bottom of a table, unless forced to.
att_is_table_row   = 500
att_tr_dynamic_data = 501

glue_spec_node = node.id("glue_spec")
glue_node      = node.id("glue")
glyph_node     = node.id("glyph")
rule_node      = node.id("rule")
penalty_node   = node.id("penalty")
whatsit_node   = node.id("whatsit")
hlist_node     = node.id("hlist")

pdf_literal_node = node.subtype("pdf_literal")

publisher.alternating = {}

default_areaname = "__seite"

-- the language of the layout instructions ('en' or 'de')
current_layoutlanguage = nil

seiten   = {}

-- CSS properties. Use `:matches(tbl)` to find a matching rule. `tbl` has the following structure: `{element=..., id=..., class=... }`
css = do_luafile("css.lua"):new()

-- The defaults (set in the layout instructions file)
options = {
  gridwidth = tex.sp("10mm"),
  gridheight = tex.sp("10mm"),
}

-- List of virtual areas. Key is the group name and value is
-- a hash with keys contents (a nodelist) and raster (grid).
groups   = {}

variablen = {}
colors    = { Schwarz = { modell="grau", g = "0", pdfstring = " 0 G 0 g " } }
colortable = {}
data_dispatcher = {}
user_defined_functions = { last = 0}
markers = {}

-- die aktuelle Gruppe
current_group = nil
current_grid = nil


-- The array 'masterpages' has tables similar to these:
-- { ist_seitentyp = test, res = tab, name = pagetypename }
-- where `ist_seitentyp` is an xpath expression to be evaluated,
-- `res` is a table with layoutxml instructions 
-- `name` is a string.
masterpages = {}


--- Text formats is a hash with arbitrary names as keys and the values
--- are tables with alignment and indent. indent is the amount of 
--- indentation in sp. alignment is one of "leftaligned", "rightaligned", 
--- "centered" and "justified"
textformats = {
  text           = { indent = 0, alignment="justified",   rows = 1},
  __centered     = { indent = 0, alignment="centered",    rows = 1},
  __leftaligned  = { indent = 0, alignment="leftaligned", rows = 1},
  __rightaligned = { indent = 0, alignment="rightaligned",rows = 1}
}

-- Liste der Schriftarten und deren Synonyme. Beispielsweise könnte ein Schlüssel `Helvetica` sein,
-- der Eintrag dann `texgyreheros-regular.otf`
-- schrifttabelle = {}

--- We map from sybolic names to (part of) file names. The hyphenation pattern files are 
--- in the format `hyph-XXX.pat.txt` and we need to find out that `XXX` part.
language_mapping = {
     ["German"]                       = "de-1996",
     ["Englisch (Great Britan)"]      = "en-gb",
     ["French"]                       = "fr",
}

--- Once a hyphenation pattern file is loaded, we only need the _id_ of it. This is stored in the
--- `languages` table. Key is the filename part (such as `de-1996`) and the value is the internal
--- language id.
languages = {}

--- The bookmarks table has the format
---     bookmarks = {
---       { --- first bookmark
---         name = "outline 1" destination = "..." open = true,
---          { name = "outline 1.1", destination = "..." },
---          { name = "outline 1.2", destination = "..." }
---       },
---       { -- second bookmark
---         name = "outline 2" destination = "..." open = false,
---          { name = "outline 2.1", destination = "..." },
---          { name = "outline 2.2", destination = "..." }
---    
---       }
---     }
bookmarks = {}

--- A table with key namespace prefix (`de` or `en`) and value namespace. Example:
---
---    {
---      [""] = "urn:speedata.de:2009/publisher/de"
---      sd = "urn:speedata:2009/publisher/functions/de"
---    }
namespaces_layout = nil

--- The dispatch table maps every element in the layout xml to a command in the `commands.lua` file.
local dispatch_table = {
  Paragraph               = commands.paragraph,
  Action                  = commands.action,
  Attribute               = commands.attribute,
  B                       = commands.bold,
  Barcode                 = commands.barcode,
  ProcessNode             = commands.process_node,
  ProcessRecord           = commands.process_record,
  AtPageShipout           = commands.atpageshipout,
  AtPageCreation          = commands.atpagecreation,
  Image                   = commands.image,
  Box                     = commands.box,
  Bookmark                = commands.bookmark,
  Record                  = commands.record,
  DefineColor             = commands.define_color,
  DefineFontfamily        = commands.define_fontfamily,
  DefineTextformat        = commands.define_textformat,
  Element                 = commands.element,
  ForAll                  = commands.forall,
  Switch                  = commands.switch,
  Group                   = commands.group,
  I                       = commands.italic,
  Include                 = commands.include,
  ["Copy-of"]             = commands.copy_of,
  LoadDataset             = commands.load_dataset,
  LoadFontfile            = commands.load_fontfile,
  Loop                    = commands.loop,
  EmptyLine               = commands.emptyline,
  Rule                    = commands.rule,
  Mark                    = commands.mark,
  Message                 = commands.message,
  NextFrame               = commands.next_frame,
  NewPage                 = commands.new_page,
  NextRow                 = commands.next_row,
  Options                 = commands.options,
  PlaceObject             = commands.place_object,
  PositioningArea         = commands.positioning_area,
  PositioningFrame        = commands.positioning_frame,
  Margin                  = commands.margin,
  Grid                    = commands.grid,
  Fontface                = commands.fontface,
  Pagetype                = commands.pagetype,
  Pageformat              = commands.page_format,
  SetGrid                 = commands.set_grid,
  Sequence                = commands.sequence,
  While                   = commands.while_do,
  SortSequence            = commands.sort_sequence,
  SaveDataset             = commands.save_dataset,
  Column                  = commands.column,
  Columns                 = commands.columns,
  Sub                     = commands.sub,
  Sup                     = commands.sup,
  Stylesheet              = commands.stylesheet,
  Table                   = commands.table,
  Tablefoot               = commands.tablefoot,
  Tablehead               = commands.tablehead,
  Textblock               = commands.textblock,
  Hyphenation             = commands.hyphenation,
  Tablerule               = commands.tablerule,
  Tr                      = commands.tr,
  Td                      = commands.td,
  U                       = commands.underline,
  URL                     = commands.url,
  Variable                = commands.variable,
  Value                   = commands.value,
  SetVariable             = commands.setvariable,
  AddToList               = commands.add_to_list,
}

--- Return the element name as an english string. The argument is in the
--- current language of the layout file (currently English and German).
function translate_element( eltname )
  return translations[current_layoutlanguage].elements[eltname]
end

--- Return the value as an english string. The argument is in the
--- current language of the layout file (currently English and German).
--- All translations are only valid in a context which defaults to the
--- _global_ context.
function translate_value( value,context )
  context = context or "*"
  local tmp = translations[current_layoutlanguage].values[context][value]
  return tmp
end

--- Return the attribute name as an english string. The argument is in the
--- current language of the layout file (currently English and German).
function translate_attribute( attname )
  return translations.attributes[attname][current_layoutlanguage]
end

--- The returned table is an array with hashes. The keys of these
--- hashes are `elementname` and `contents`. For example:
---    {
---      [1] = {
---        ["elementname"] = "Paragraph"
---        ["contents"] = {
---          ["nodelist"] = "<node    nil <  58515 >    nil : glyph 1>"
---        },
---      },
---    },
function dispatch(layoutxml,dataxml,optionen)
  local ret = {}
  local tmp
  for _,j in ipairs(layoutxml) do
    -- j a table, if it is an element in layoutxml
    if type(j)=="table" then
      local eltname = translate_element(j[".__name"])
      if dispatch_table[eltname] ~= nil then
        tmp = dispatch_table[eltname](j,dataxml,optionen)

        -- Copy-of-elements can be resolveld immediately 
        if eltname == "Copy-of" or eltname == "Switch" or eltname == "ForAll" or eltname == "Loop" then
          if type(tmp)=="table" then
            for i=1,#tmp do
              if tmp[i].contents then
                ret[#ret + 1] = { elementname = tmp[i].elementname, contents = tmp[i].contents }
              else
                ret[#ret + 1] = { elementname = "elementstructure" , contents = { tmp[i] } }
              end
            end
          end
        else
          ret[#ret + 1] =   { elementname = eltname, contents = tmp }
        end
      else
        err("Unknown element found in layoutfile: %q", eltname or "???")
        printtable("j",j)
      end
    end
  end
  return ret
end

--- Convert the argument `str` (in UTF-8) to a string suitable for writing into the PDF file. The returned string starts with `<feff` and ends with `>`
function utf8_to_utf16_string_pdf( str )
  local ret = {}
  for s in string.utfvalues(str) do
    ret[#ret + 1] = fontloader.to_utf16(s)
  end
  local utf16str = "<feff" .. table.concat(ret) .. ">"
  return utf16str
end

--- Bookmarks are collected and later processed. This function (recursively)
--- creates TeX code from the generated tables.
function bookmarkstotex( tbl )
  local countstring
  local open_string
  if #tbl == 0 then
    countstring = ""
  else
    if tbl.open == "true" then
      open_string = ""
        else
      open_string = "-"
    end
    countstring = string.format("count %s%d",open_string,#tbl)
  end
  if tbl.destination then
    tex.sprint(string.format("\\pdfoutline goto num %s %s {%s}",tbl.destination, countstring ,utf8_to_utf16_string_pdf(tbl.name) ))
  end
  for i,v in ipairs(tbl) do
    bookmarkstotex(v)
  end
end

--- Start the processing (`dothings()`)
--- -------------------------------
--- This is the entry point of the processing. It is called from `spinit.lua`/`main_loop()`.
function dothings()
  page_initialized=false

  --- First we set some defaults.
  --- A4 paper is 210x297 mm
  set_pageformat(tex.sp("210mm"),tex.sp("297mm"))

  --- The free font family `TeXGyreHeros` is a Helvetica clone and is part of the 
  --- [The TeX Gyre Collection of Fonts](http://www.gust.org.pl/projects/e-foundry/tex-gyre).
  --- We ship it in the distribution.
  fonts.load_fontfile("TeXGyreHeros-Regular",   "texgyreheros-regular.otf")
  fonts.load_fontfile("TeXGyreHeros-Bold",      "texgyreheros-bold.otf")
  fonts.load_fontfile("TeXGyreHeros-Italic",    "texgyreheros-italic.otf")
  fonts.load_fontfile("TeXGyreHeros-BoldItalic","texgyreheros-bolditalic.otf")
  --- Define a basic font family with name `text`:
  define_default_fontfamily()

  --- The default page type has 1cm margin
  local onecm=tex.sp("1cm")
  masterpages[1] = { ist_seitentyp = "true()", res = { {elementname = "Margin", contents = function(_seite) _seite.raster:set_margin(onecm,onecm,onecm,onecm) end }}, name = "Seite",ns={} }

  --- Both the data and the layout instructions are written in XML.
  local layoutxml = load_xml(arg[2],"layout instructions")
  if not layoutxml then
    err("Without a valid layout-XML file, I can't really do anything.")
    exit()
  end
  -- We allow the use of a dummy xml file for testing purpose
  local dataxml
  if arg[3] == "-dummy" then
    dataxml = luxor.parse_xml("<data />")
  elseif arg[3] == "-" then
    log("Reading from stdin")
    dataxml = luxor.parse_xml(io.stdin:read("*a"),{htmlentities = true})
  else
    dataxml = load_xml(arg[3],"data file")
  end

  --- The `vars` file hold a lua document holding table
  local vars = loadfile(tex.jobname .. ".vars")()
  for k,v in pairs(vars) do
    variablen[k]=v
  end

  --- Used in `xpath.lua` to find out which language the function is in.
  local ns = layoutxml[".__namespace"]

  --- The currently active layout language. One of `de` or `en`.
  current_layoutlanguage = string.gsub(ns,"urn:speedata.de:2009/publisher/","")
  if not (current_layoutlanguage=='de' or current_layoutlanguage=='en') then
    err("Cannot determine the language of the layout file.")
    exit()
  end
  dispatch(layoutxml)

  --- override options set in the `<Options>` element
  if arg[4] then
    for _,extopt in ipairs(string.explode(arg[4],",")) do
      if string.len(extopt) > 0 then
        local k,v = extopt:match("^(.+)=(.+)$")
        v = v:gsub("^\"(.*)\"$","%1")
        options[k]=v
      end
    end
  end
  if options.showgrid == "false" then
    options.showgrid = false
  elseif options.showgrid == "true" then
    options.showgrid = true
  end

  --- Set the starting page (which must be a number)
  if options.startpage then
    local num = options.startpage
    if num then
      tex.count[0] = num - 1
      log("Set page number to %d",num)
    else
      err("Can't recognize starting page number %q",options.startpage)
    end
  end

  --- Start data processing in the default mode (`""`)
  local tmp
  local name = dataxml[".__name"]
  --- The rare case that the user has not any `Record` commands in the layout file:
  if not data_dispatcher[""] then
    err("Can't find »Record« command for the root node.")
    exit()
  end
  tmp = data_dispatcher[""][name]
  if tmp then publisher.dispatch(tmp,dataxml) end


  --- emit last page if necessary
  if page_initialized then
    dothingsbeforeoutput()
    local n = node.vpack(publisher.global_pagebox)

    tex.box[666] = n
    tex.shipout(666)
  end

  --- At this point, all pages are in the PDF
  pdf.catalog = [[ /PageMode /UseOutlines ]]
  pdf.info    = [[ /Creator	(speedata Publisher) /Producer(speedata Publisher, www.speedata.de) ]]

  --- Now put the bookmarks in the pdf
  for _,v in ipairs(bookmarks) do
    bookmarkstotex(v)
  end

end

--- Load an XML file from the harddrive. filename is without path but including extension,
--- filetype is a string representing the type of file read, such as "layout" or "data".
--- The return value is a lua table representing the XML file.
---
--- The XML file
---
---     <?xml version="1.0" encoding="UTF-8"?>
---     <data>
---       <element attribute="whatever">
---         <subelement>text in subelement</subelement>
---       </element>
---     </data>
---
--- is represented by this Lua table:
---     XML = {
---       [1] = " "
---       [2] = {
---         [1] = " "
---         [2] = {
---           [1] = "text in subelement"
---           [".__parent"] = (pointer to the "element" tree, which is the second entry in the top level)
---           [".__name"] = "subelement"
---         },
---         [3] = " "
---         [".__parent"] = (pointer to the root element)
---         [".__name"] = "element"
---         ["attribute"] = "whatever"
---       },
---       [3] = " "
---       [".__name"] = "data"
---     },
function load_xml(filename,filetype)
  local path = kpse.find_file(filename)
  if not path then
    err("Can't find XML file %q. Abort.\n",filename or "?")
    os.exit(-1)
  end
  log("Loading %s %q",filetype or "file",path)
  return luxor.parse_xml_file(path, { htmlentities = true })
end

--- Place an object at a position given in scaled points (_x_ and _y_). `allocate` is ignored at at the moment.
function output_absolute_position( nodelist,x,y,allocate,bereich )

  if node.has_attribute(nodelist,att_shift_left) then
    x = x - node.has_attribute(nodelist,att_shift_left)
    y = y - node.has_attribute(nodelist,att_shift_up)
  end

  local n = add_glue( nodelist ,"head",{ width = x })
  n = node.hpack(n)
  n = add_glue(n, "head", {width = y})
  n = node.vpack(n)
  n.width  = 0
  n.height = 0
  n.depth  = 0
  local tail = node.tail(publisher.global_pagebox)
  tail.next = n
  n.prev = tail
end

--- Put the object (nodelist) on grid cell (x,y). If `allocate`=`true` then
--- mark cells as occupied.
function ausgabe_bei( nodelist, x,y,allocate,bereich,valign,allocate_matrix)

  bereich = bereich or default_areaname
  local r = current_grid
  local wd = nodelist.width
  local ht = nodelist.height + nodelist.depth
  local breite_in_rasterzellen = r:width_in_gridcells_sp(wd)
  local hoehe_in_rasterzellen  = r:height_in_gridcells_sp (ht)

  local delta_x, delta_y = r:position_rasterzelle_mass_tex(x,y,bereich,wd,ht,valign)
  if not delta_x then
    err(delta_y)
    exit()
  end

  if node.has_attribute(nodelist,att_shift_left) then
    delta_x = delta_x - node.has_attribute(nodelist,att_shift_left)
    delta_y = delta_y - node.has_attribute(nodelist,att_shift_up)
  end

  --- We don't necessarily ouput things on a page, we can output them in a virtual page, called _group_.
  if current_group then
    -- Put the contents of the nodelist into the current group
    local group = groups[current_group]
    assert(group)

    local n = add_glue( nodelist ,"head",{ width = delta_x })
    n = node.hpack(n)
    n = add_glue(n, "head", {width = delta_y})
    n = node.vpack(n)

    if group.contents then
      -- There is already something in the group, we must add the new nodelist. 
      -- The size of the new group: max(size of old group, size of new nodelist)
      local new_width, new_height
      new_width  = math.max(n.width, group.contents.width)
      new_height = math.max(n.height + n.depth, group.contents.height + group.contents.depth)

      group.contents.width  = 0
      group.contents.height = 0
      group.contents.depth  = 0

      local tail = node.tail(group.contents)
      tail.next = n
      n.prev = tail

      group.contents = node.vpack(group.contents)
      group.contents.width  = new_width
      group.contents.height = new_height
      group.contents.depth  = 0
    else
      -- group is empty
      group.contents = n
    end
    if allocate then
      r:allocate_cells(x,y,breite_in_rasterzellen,hoehe_in_rasterzellen,allocate_matrix,options.showgridallocation)
    end
  else
    -- Put it on the current page
    if allocate then
      r:allocate_cells(x,y,breite_in_rasterzellen,hoehe_in_rasterzellen,allocate_matrix,options.showgridallocation,bereich)
    end

    local n = add_glue( nodelist ,"head",{ width = delta_x })
    n = node.hpack(n)
    n = add_glue(n, "head", {width = delta_y})
    n = node.vpack(n)
    n.width  = 0
    n.height = 0
    n.depth  = 0
    local tail = node.tail(publisher.global_pagebox)
    tail.next = n
    n.prev = tail

  end
end

--- Return the XML structure that is stored at &lt;pagetype>. For every pagetype
--- in the table "masterpages" the function ist_seitentyp() gets called-
function detect_pagetype()
  local ret = nil
  for i=#masterpages,1,-1 do
    local seitentyp = masterpages[i]
    if xpath.parse(nil,seitentyp.ist_seitentyp,seitentyp.ns) == true then
      log("Page of type %q created",seitentyp.name or "<detect_pagetype>")
      ret = seitentyp.res
      return ret
    end
  end
  err("Can't find correct page type!")
  return false
end

--- _Must_ be called before something can be put on the page. Looks for hooks to be run before page creation.
function setup_page()
  if page_initialized then return end
  page_initialized=true
  publisher.global_pagebox = node.new("vlist")
  local trim_amount = tex.sp(options.trim or 0)
  local extra_margin
  if options.cutmarks then
    extra_margin = tex.sp("1cm") + trim_amount
  elseif trim_amount > 0 then
    extra_margin = trim_amount
  end
  local errorstring

  current_page, errorstring = seite:new(options.pagewidth,options.seitenhoehe, extra_margin, trim_amount)
  if not current_page then
    err("Can't create a new page. Is the page type (»PageType«) defined? %s",errorstring)
    exit()
  end
  current_grid = current_page.raster
  seiten[tex.count[0]] = nil
  tex.count[0] = tex.count[0] + 1
  seiten[tex.count[0]] = current_page

  local gridwidth = options.gridwidth
  local gridheight  = options.gridheight


  local pagetype = detect_pagetype()
  if pagetype == false then return false end

  for _,j in ipairs(pagetype) do
    local eltname = elementname(j,true)
    if type(element_contents(j))=="function" and eltname=="Margin" then
      element_contents(j)(current_page)
    elseif eltname=="Grid" then
      gridwidth = element_contents(j).breite
      gridheight  = element_contents(j).hoehe
    end
  end

  if not gridwidth then
    err("Grid is not set!")
    exit()
  end
  assert(gridwidth)
  assert(gridheight,"Gridheight!")
  current_page.raster:set_width_height(gridwidth,gridheight)

  for _,j in ipairs(pagetype) do
    local eltname = elementname(j,true)
    if type(element_contents(j))=="function" and eltname=="Margin" then
      -- do nothing, done before
    elseif eltname=="Grid" then
      -- do nothing, done before
    elseif eltname=="AtPageCreation" then
      current_page.atpagecreation = element_contents(j)
    elseif eltname=="AtPageShipout" then
      current_page.AtPageShipout = element_contents(j)
    elseif eltname=="PositioningArea" then
      local name = element_contents(j).name
      current_grid.positioning_frames[name] = {}
      local current_positioning_area = current_grid.positioning_frames[name]
      -- we evaluate now, because the attributes in PositioningFrame can be page dependent.
      local tab  = publisher.dispatch(element_contents(j).layoutxml,dataxml)
      for i,k in ipairs(tab) do
        current_positioning_area[#current_positioning_area + 1] = element_contents(k)
      end
    else
      err("Element name %q unknown (setup_page())",eltname or "<create_page>")
    end
  end


  if current_page.atpagecreation then
    publisher.dispatch(current_page.atpagecreation,nil)
  end
end

--- Switch to the next frame in the given are. 
function next_area( areaname )
  local aktuelle_nummer = current_grid:rahmennummer(areaname)
  if not aktuelle_nummer then
    err("Cannot determine current area number (areaname=%q)",areaname or "(undefined)")
    return
  end
  if aktuelle_nummer >= current_grid:anzahl_rahmen(areaname) then
    new_page()
  else
    current_grid:set_framenumber(areaname, aktuelle_nummer + 1)
  end
  current_grid:set_current_row(1,areaname)
end

--- Switch to a new page and shipout the current page. 
--- This new page is only created if something is typeset on it.
function new_page()
  if pagebreak_impossible then
    return
  end
  if not current_page then
    -- es wurde new_page() aufgerufen, ohne, dass was ausgegeben wurde bisher
    page_initialized=false
    setup_page()
  end
  if current_page.AtPageShipout then
    pagebreak_impossible = true
    dispatch(current_page.AtPageShipout)
    pagebreak_impossible = false
  end
  page_initialized=false
  dothingsbeforeoutput()
  current_page = nil

  local n = node.vpack(publisher.global_pagebox)
  tex.box[666] = n
  tex.shipout(666)
end

--- Draw a background behind the rectangular (box) object.
function background( box, colorname )
  if not colors[colorname] then
    warning("Background: Color %q is not defined",colorname)
    return box
  end
  local pdfcolorstring = colors[colorname].pdfstring
  local wd, ht, dp = sp_to_bp(box.width),sp_to_bp(box.height),sp_to_bp(box.depth)
  n = node.new(whatsit_node,pdf_literal_node)
  n.data = string.format("q %s 0 -%g %g %g re f Q",pdfcolorstring,dp,wd,ht + dp)
  n.mode = 0
  if node.type(box.id) == "hlist" then
    -- pdfliteral does not use up any space, so we can add it to the already packed box.
    n.next = box.list
    box.list.prev = n
    box.list = n
    return box
  else
    n.next = box
    box.prev = n
    n = node.hpack(n)
    return n
  end
end

--- Draw a frame around the given TeX box with color `colorname`.
function frame( box, colorname, width )
  local pdfcolorstring = colors[colorname].pdfstring
  local wd, ht, dp = sp_to_bp(box.width),sp_to_bp(box.height),sp_to_bp(box.depth)
  local w = width / factor -- width of stroke
  local hw = 0.5 * w -- half width of stroke
  n = node.new(whatsit_node,pdf_literal_node)
  n.data = string.format("q %s %g w -%g -%g %g %g re S Q",pdfcolorstring, w , hw ,dp + hw ,wd + w,ht + dp + w)
  n.mode = 0
  n.next = box
  box.prev = n
  n = node.hpack(n)
  return n
end

--- Create a colored area. width and height are in dtp points.
function box( width,height,colorname )
  local n = node.new(whatsit_node,pdf_literal_node)
  n.data = string.format("q %s 1 0 0 1 0 0 cm 0 0 %g -%g re f Q",colors[colorname].pdfstring,width,height)
  n.mode = 0
  return n
end

--- After everything is ready for page shipout, we add debug output and crop marks if necessary
function dothingsbeforeoutput(  )
  local r = current_page.raster
  local str
  find_user_defined_whatsits(publisher.global_pagebox)
  local firstbox

  -- White background on page. Todo: Make color customizable and background optional.
  local wd = sp_to_bp(current_page.width)
  local ht = sp_to_bp(current_page.height)

  local x = 0 + current_page.raster.extra_rand
  local y = 0 + current_page.raster.extra_rand + current_page.raster.rand_oben

  if options.trim then
    local trim_bp = sp_to_bp(options.trim)
    wd = wd + trim_bp * 2
    ht = ht + trim_bp * 2
    x = x - options.trim
    y = y - options.trim
  end

  firstbox = node.new("whatsit","pdf_literal")
  firstbox.data = string.format("q 0 0 0 0 k  1 0 0 1 0 0 cm %g %g %g %g re f Q",sp_to_bp(x), sp_to_bp(y),wd ,ht)
  firstbox.mode = 1

  if options.showgridallocation then
    local lit = node.new("whatsit","pdf_literal")
    lit.mode = 1
    lit.data = r:draw_gridallocation()

    if firstbox then
      local tail = node.tail(firstbox)
      tail.next = lit
      lit.prev = tail
    else
      firstbox = lit
    end
  end

  if options.showgrid then
    local lit = node.new("whatsit","pdf_literal")
    lit.mode = 1
    lit.data = r:zeichne_raster()
    if firstbox then
      local tail = node.tail(firstbox)
      tail.next = lit
      lit.prev = tail
    else
      firstbox = lit
    end
  end
  r:trimbox()
  if options.cutmarks then
    local lit = node.new("whatsit","pdf_literal")
    lit.mode = 1
    lit.data = r:beschnittmarken()
    if firstbox then
      local tail = node.tail(firstbox)
      tail.next = lit
      lit.prev = tail
    else
      firstbox = lit
    end
  end
  if firstbox then
    local list_start = publisher.global_pagebox
    publisher.global_pagebox = firstbox
    node.tail(firstbox).next = list_start
    list_start.prev = node.tail(firstbox)
  end
end

--- Read the contents of the attribute `attname_english.` `typ` is one of
--- `string`, `number`, `length` and `boolean`.
--- `default` gives something that is to be returned if no attribute with this name is present.
function read_attribute( layoutxml,dataxml,attname_english,typ,default,context)
  local namespaces = layoutxml[".__ns"]
  local attname = translate_attribute(attname_english)

  if not layoutxml[attname] then
    return default -- can be nil
  end

  local val,num,ret
  local xpathstring = string.match(layoutxml[attname],"{(.-)}")
  if xpathstring then
    val = xpath.textvalue(xpath.parse(dataxml,xpathstring,namespaces))
  else
    val = layoutxml[attname]
  end

  if typ=="xpath" then
    return xpath.textvalue(xpath.parse(dataxml,val,namespaces))
  elseif typ=="xpathraw" then
    return xpath.parse(dataxml,val,namespaces)
  elseif typ=="rawstring" then
    return tostring(val)
  elseif typ=="string" then
    return tostring(translate_value(val,context) or default)
  elseif typ=="number" then
    return tonumber(val)
  -- something like "3pt"
  elseif typ=="length" then
    return val
  -- same as before, just changed to scaled points
  elseif typ=="length_sp" then
    num = tonumber(val or default)
    if num then -- most likely really a number, we need to multiply with grid width
      ret = current_page.raster.gridwidth * num
    else
      ret = val
    end
    return tex.sp(ret)
  elseif typ=="height_sp" then
    num = tonumber(val or default)
    if num then -- most likely really a number, we need to multiply with grid height
      ret = current_page.raster.gridheight * num
    else
      ret = val
    end
    return tex.sp(ret)
  elseif typ=="boolean" then
    if val then
      val = translate_value(val,context)
    else
      val = default
    end
    if val=="yes" then
      return true
    elseif val=="no" then
      return false
    end
    return nil
  else
    warning("read_attribut (2): unknown type: %s",type(val))
  end
  return val
end

-- Return the element name of the given element (elt) and translate it
-- into english, unless raw_p is true.
function elementname( elt ,raw_p)
  trace("elementname = %q",elt.elementname or "?")
  if raw_p then return elt.elementname end
  trace("translated = %q",translate_element(elt.elementname) or "?")
  return translate_element(elt.elementname)
end

--- Return the contents of an entry from the `dispatch()` function call.
function element_contents( elt )
  return elt.contents
end

--- Convert `<b>`, `<u>` and `<i>` in text to publisher recognized elements.
function parse_html( elt )
  local a = paragraph:new()
  local bold,italic,underline
  if elt[".__name"] then
    if elt[".__name"] == "b" or elt[".__name"] == "B" then
      bold = 1
    elseif elt[".__name"] == "i" or elt[".__name"] == "I" then
      italic = 1
    elseif elt[".__name"] == "u" or elt[".__name"] == "U" then
      underline = 1
    end
  end

  for i=1,#elt do
    if type(elt[i]) == "string" then
      a:append(elt[i],{fontfamily = 0, bold = bold, italic = italic, underline = underline })
    elseif type(elt[i]) == "table" then
      a:append(parse_html(elt[i]),{fontfamily = 0, bold = bold, italic = italic, underline = underline})
    end
  end

  return a
end

--- Look for `user_defined` at end of page (shipout) and runs actions encoded in them.
function find_user_defined_whatsits( head )
  local typ,fun
  while head do
    typ = node.type(head.id)
    if typ == "vlist" or typ=="hlist" then
      find_user_defined_whatsits(head.list)
    elseif typ == "whatsit" then
      if head.subtype == 44 then
        -- action
        if head.user_id == 1 then
          -- der Wert ist der Index für die Funktion unter user_defined_functions.
          fun = user_defined_functions[head.value]
          fun()
          -- use and forget
          user_defined_functions[head.value] = nil
        -- bookmark
        elseif head.user_id == 2 then
          local level,openclose,dest,str =  string.match(head.value,"([^+]*)+([^+]*)+([^+]*)+(.*)")
          level = tonumber(level)
          local open_p
          if openclose == "1" then
            open_p = true
          else
            open_p = false
          end
          local i = 1
          local current_bookmark_table = bookmarks -- level 1 == top level
          -- create levels if necessary
          while i < level do
            if #current_bookmark_table == 0 then
              current_bookmark_table[1] = {}
              err("No bookmark given for this level (%d)!",level)
            end
            current_bookmark_table = current_bookmark_table[#current_bookmark_table]
            i = i + 1
          end
          current_bookmark_table[#current_bookmark_table + 1] = {name = str, destination = dest, open = open_p}
        elseif head.user_id == 3 then
          local marker = head.value
          publisher.markers[marker] = { page = tex.count[0] }
        end
      end
    end
    head = head.next
  end
end

rightskip = node.new(glue_spec_node)
rightskip.width = 0
rightskip.stretch = 1 * 2^16
rightskip.stretch_order = 3

leftskip = node.new(glue_spec_node)
leftskip.width = 0
leftskip.stretch = 1 * 2^16
leftskip.stretch_order = 3

--- Create a `\hbox`. Return a nodelist. Parameter is one of
--- 
--- * languagecode
--- * bold (bold)
--- * italic (italic)
--- * underline
function mknodes(str,fontfamily,parameter)
  -- instance is the internal fontnumber
  local instance
  local instancename
  local languagecode = parameter.languagecode or 0
  if parameter.bold == 1 then
    if parameter.italic == 1 then
      instancename = "bolditalic"
    else
      instancename = "bold"
    end
  elseif parameter.italic == 1 then
    instancename = "italic"
  else
    instancename = "normal"
  end

  if fontfamily and fontfamily > 0 then
    instance = fonts.lookup_fontfamily_number_instance[fontfamily][instancename]
  else
    instance = 1
  end

  local tbl = font.getfont(instance)
  local space   = tbl.parameters.space
  local shrink  = tbl.parameters.space_shrink
  local stretch = tbl.parameters.space_stretch
  local match = unicode.utf8.match

  local head, last, n
  local char

  -- if it's an empty string, we make it a space character (experimental)
  if string.len(str) == 0 then
    n = node.new(glyph_node)
    n.char = 32
    n.font = instance
    n.subtype = 1
    n.char = s
    if languagecode then
      n.lang = languagecode
    else
      n.lang = 0
    end

    node.set_attribute(n,att_fontfamily,fontfamily)
    return n
  end
  -- There is a string with utf8 chars
  for s in string.utfvalues(str) do
    local char = unicode.utf8.char(s)
    -- If the next char is a newline (&amp;#x0A;) a \\ is inserted
    if s == 10 then
      local strut
      strut = add_rule(nil,"head",{height = 8 * publisher.factor, depth = 3 * publisher.factor, width = 0 })
      head,last = node.insert_after(head,last,strut)

      local p1,g,p2
      p1 = node.new(penalty_node)
      p1.penalty = 10000

      g = node.new(glue_node)
      g.spec = node.new(glue_spec_node)
      g.spec.stretch = 2^16
      g.spec.stretch_order = 2

      p2 = node.new(penalty_node)
      p2.penalty = -10000

      head,last = node.insert_after(head,last,p1)
      head,last = node.insert_after(head,last,g)
      head,last = node.insert_after(head,last,p2)

    elseif match(char,"%s") and last and last.id == glue_node and not node.has_attribute(last,att_tie_glue,1) then
      -- double space, don't do anything
    elseif s == 160 then -- non breaking space
      n = node.new(penalty_node)
      n.penalty = 10000

      head,last = node.insert_after(head,last,n)

      n = node.new(glue_node)
      n.spec = node.new(glue_spec_node)
      n.spec.width   = space
      n.spec.shrink  = shrink
      n.spec.stretch = stretch

      node.set_attribute(n,att_tie_glue,1)

      head,last = node.insert_after(head,last,n)

      if parameter.underline == 1 then
        node.set_attribute(n,att_underline,1)
      end
      node.set_attribute(n,att_fontfamily,fontfamily)


    elseif match(char,"%s") then -- Space
      n = node.new(glue_node)
      n.spec = node.new(glue_spec_node)
      n.spec.width   = space
      n.spec.shrink  = shrink 
      n.spec.stretch = stretch

      if parameter.underline == 1 then
        node.set_attribute(n,att_underline,1)
      end
      node.set_attribute(n,att_fontfamily,fontfamily)

      head,last = node.insert_after(head,last,n)
    else
      -- A regular character?!?
      n = node.new(glyph_node)
      n.font = instance
      n.subtype = 1
      n.char = s
      n.lang = languagecode
      n.uchyph = 1
      n.left = tex.lefthyphenmin
      n.right = tex.righthyphenmin
      node.set_attribute(n,att_fontfamily,fontfamily)
      if parameter.bold == 1 then
        node.set_attribute(n,att_bold,1)
      end
      if parameter.italic == 1 then
        node.set_attribute(n,att_italic,1)
      end
      if parameter.underline == 1 then
        node.set_attribute(n,att_underline,1)
      end
      head,last = node.insert_after(head,last,n)
      -- We have a character but some characters must be treated in a special
      -- way.
      -- Hyphens must be sepearated from words:
      if n.char == 45 then
        local pen = node.new("penalty")
        pen.penalty = 10000

        head = node.insert_before(head,last,pen)

        local glue = node.new("glue")
        glue.spec = node.new("glue_spec")
        glue.spec.width = 0
        if parameter.underline == 1 then
          node.set_attribute(glue,att_underline,1)
        end
        head,last = node.insert_after(head,last,glue)
        node.set_attribute(glue,att_tie_glue,1)
      elseif match(char,"[;:]") then
        -- and ;: should have the posibility to break easily after.
        n = node.new(penalty_node)
        n.penalty = 0
        head,last = node.insert_after(head,last,n)
      end
    end
  end

  if not head then
    -- This should never happen.
    warning("No head found")
    return node.new("hlist")
  end
  return head
end

-- head_or_tail = "head" oder "tail" (default: tail). Return new head (perhaps same as nodelist)
function add_rule( nodelist,head_or_tail,parameters)
  parameters = parameters or {}
  -- if parameters.height == nil then parameters.height = -1073741824 end
  -- if parameters.width  == nil then parameters.width  = -1073741824 end
  -- if parameters.depth  == nil then parameters.depth  = -1073741824 end

  local n=node.new(rule_node)
  n.width  = parameters.width
  n.height = parameters.height
  n.depth  = parameters.depth
  if not nodelist then return n end

  if head_or_tail=="head" then
    n.next = nodelist
    nodelist.prev = n
    return n
  else
    local last=node.slide(nodelist)
    last.next = n
    n.prev = last
    return nodelist,n
  end
  assert(false,"never reached")
end

-- Add a glue to the front or tail of the given nodelist. `head_or_tail` is
-- either the string `head` or `tail`. `parameter` is a table with the keys
-- `width`, `stretch` and `stretch_order`. If the nodelist is nil, a simple
-- node list consisting of a glue will be created.
function add_glue( nodelist,head_or_tail,parameter)
  parameter = parameter or {}

  local n=node.new(glue_node, parameter.subtype or 0)
  n.spec = node.new(glue_spec_node)
  n.spec.width         = parameter.width
  n.spec.stretch       = parameter.stretch
  n.spec.stretch_order = parameter.stretch_order

  if nodelist == nil then return n end

  if head_or_tail=="head" then
    n.next = nodelist
    nodelist.prev = n
    return n
  else
    local last=node.slide(nodelist)
    last.next = n
    n.prev = last
    return nodelist,n
  end
  assert(false,"never reached")
end

function make_glue( parameter )
  local n = node.new("glue")
  n.spec = node.new("glue_spec")
  n.spec.width         = parameter.width
  n.spec.stretch       = parameter.stretch
  n.spec.stretch_order = parameter.stretch_order
  return n
end

function finish_par( nodelist,hsize )
  assert(nodelist)
  node.slide(nodelist)
  lang.hyphenate(nodelist)
  local n = node.new(penalty_node)
  n.penalty = 10000
  local last = node.slide(nodelist)

  last.next = n
  n.prev = last
  last = n

  n = node.kerning(nodelist)
  n = node.ligaturing(n)

  n,last = add_glue(n,"tail",{ subtype = 15, width = 0, stretch = 2^16, stretch_order = 2})
end

function fix_justification( nodelist,textformat,parent)
  local head = nodelist
  while head do
    if head.id == 0 then -- hlist
      -- we are on a line now. We assume that the spacing needs correction.
      -- The goal depends on the current line (parshape!)
      local goal,_,_ = node.dimensions(head.glue_set, head.glue_sign, head.glue_order, head.head)
      local font_before_glue

      -- The following code is problematic, in tabular material. This is my older comment
      -- There was code here (39826d4c5 and before) that changed
      -- the glue depending on the font before that glue. That
      -- was problematic, because LuaTeX does not copy the 
      -- altered glue_spec node on copy_list (in paragraph:format())
      -- which, when reformatted, gets a complaint by LuaTeX about
      -- infinite shrinkage in a paragraph

      -- a new glue spec node - we must not(!) alter the current glue spec
      -- because this list is copied in paragraph:format()
      local spec_new

      for n in node.traverse_id(10,head.head) do
        -- calculate the font before this id.
        if n.prev and n.prev.id == 37 then -- glyph
          font_before_glue = n.prev.font
        elseif n.prev and n.prev.id == 7 then -- disc
          local font_node = n.prev
          while font_node.id ~= 37 do
            font_node = font_node.prev
          end
          font_before_glue = nil
        else
          font_before_glue = nil
        end

        -- n.spec.width > 0 because we insert a glue after a hyphen in
        -- compund words mailing-[glue]list and that glue's width is 0pt
        if n.subtype==0 and font_before_glue and n.spec.width > 0 then
          spec_new = node.new("glue_spec")
          spec_new.width = font.fonts[font_before_glue].parameters.space
          spec_new.shrink_order = head.glue_order
          n.spec = spec_new
        end
      end

      if textformat == "rightaligned" then
        local wd = node.dimensions(head.glue_set, head.glue_sign, head.glue_order,head.head)
        local list_start = head.head
        local leftskip_node = node.new("glue")
        leftskip_node.spec = node.new("glue_spec")
        leftskip_node.spec.width = goal - wd
        leftskip_node.next = list_start
        list_start.prev = leftskip_node
        head.head = leftskip_node
        local tail = node.tail(head.head)

        if tail.prev.id == 10 and tail.prev.subtype==15 then -- parfillskip
          local parfillskip = tail.prev
          tail.prev = parfillskip.prev
          parfillskip.prev.next = tail
          parfillskip.next = head.head
          head.head = parfillskip
        end
      end

      if textformat == "centered" then
        local list_start = head.head
        local rightskip = node.tail(head.head)
        local leftskip_node = node.new("glue")
        leftskip_node.spec = node.new("glue_spec")
        local wd

        if rightskip.prev.id == 10 and rightskip.prev.subtype==15 then -- parfillskip
          local parfillskip = rightskip.prev

          wd = node.dimensions(head.glue_set, head.glue_sign, head.glue_order,head.head,parfillskip.prev)

          -- remove parfillksip and insert half width in rightskip
          parfillskip.prev.next = rightskip
          rightskip.prev = parfillskip.prev
          rightskip.spec = node.new("glue_spec")
          rightskip.spec.width = (goal - wd) / 2
          node.free(parfillskip)
        else
          wd = node.dimensions(head.glue_set, head.glue_sign, head.glue_order,head.head)
        end
        -- insert half width in front of the row
        leftskip_node.spec.width = ( goal - wd ) / 2
        leftskip_node.next = list_start
        list_start.prev = leftskip_node
        head.head = leftskip_node
      end

    elseif head.id == 1 then -- vlist
      fix_justification(head.head,textformat,head)
    end
    head = head.next
  end
  return nodelist
end

function do_linebreak( nodelist,hsize,parameters )
  assert(nodelist,"No nodelist found for line breaking.")
  parameters = parameters or {}
  finish_par(nodelist,hsize)

  local pdfignoreddimen
  pdfignoreddimen    = -65536000

  local default_parameters = {
    hsize = hsize,
    emergencystretch = 0.1 * hsize,
    hyphenpenalty = 0,
    linepenalty = 10,
    pretolerance = 0,
    tolerance = 2000,
    doublehyphendemerits = 1000,
    pdfeachlineheight = pdfignoreddimen,
    pdfeachlinedepth  = pdfignoreddimen,
    pdflastlinedepth  = pdfignoreddimen,
    pdfignoreddimen   = pdfignoreddimen,
  }
  setmetatable(parameters,{__index=default_parameters})
  local j = tex.linebreak(nodelist,parameters)

  -- Adjust line heights. Always take the largest font in a row.
  local head = j
  local maxskip
  while head do
    if head.id == 0 then -- hlist
      maxskip = 0
      local head_list = head.list
      while head_list do
        local fam = node.has_attribute(head_list,att_fontfamily)
        if fam then
          -- Is this necessary anymore? FIXME
          if fam == 0 then fam = 1 end
          maxskip = math.max(fonts.lookup_fontfamily_number_instance[fam].baselineskip,maxskip)
        end
        head_list = head_list.next
      end
      head.height = 0.75 * maxskip
      head.depth  = 0.25 * maxskip
    end
    head = head.next
  end

  return node.vpack(j)
end

function create_empty_hbox_with_width( wd )
  local n=node.new(glue_node,0)
  n.spec = node.new(glue_spec_node)
  n.spec.width         = 0
  n.spec.stretch       = 2^16
  n.spec.stretch_order = 3
  n = node.hpack(n,wd,"exactly")
  return n
end

do
  local destcounter = 0
  -- Create a pdf anchor (dest object). It returns a whatsit node and the 
  -- number of the anchor, so it can be used in a pdf link or an outline.
  function mkdest()
    destcounter = destcounter + 1
    local d = node.new("whatsit","pdf_dest")
    d.named_id = 0
    d.dest_id = destcounter
    d.dest_type = 3
    return d, destcounter
  end
end

-- Generate a hlist with necessary nodes for the bookmarks. To be inserted into a vlist that gets shipped out
function mkbookmarknodes(level,open_p,title)
  -- The bookmarks need three values, the level, the name and if it is 
  -- open or closed
  local openclosed 
  if open_p then openclosed = 1 else openclosed = 2 end
  level = level or 1
  title = title or "no title for bookmark given"

  n,counter = mkdest()
  local udw = node.new("whatsit","user_defined")
  udw.user_id = 2
  udw.type = 115 -- a string
  udw.value = string.format("%d+%d+%d+%s",level,openclosed,counter,title)
  n.next = udw
  udw.prev = n
  local hlist = node.hpack(n)
  return hlist
end

function boxit( box )
  local box = node.hpack(box)

  local rule_width = 0.1
  local wd = box.width                 / factor - rule_width
  local ht = (box.height + box.depth)  / factor - rule_width
  local dp = box.depth                 / factor - rule_width / 2

  local wbox = node.new("whatsit","pdf_literal")
  wbox.data = string.format("q 0.1 G %g w %g %g %g %g re s Q", rule_width, rule_width / 2, -dp, -wd, ht)
  wbox.mode = 0
  -- Draw box at the end so its contents gets "below" it.
  local tmp = node.tail(box.list)
  tmp.next = wbox
  return box
end

local images = {}
function new_image( filename, page, box)
  return imageinfo(filename,page,box)
end

-- Box is none, media, crop, bleed, trim, art
function imageinfo( filename,page,box )
  page = page or 1
  box = box or "crop"
  local new_name = filename .. tostring(page) .. tostring(box)

  if images[new_name] then
    return images[new_name]
  end

  if not find_file_location(filename) then
    err("Image %q not found!",filename or "???")
    filename = "filenotfound.pdf"
    page = 1
  end

  -- <?xml version="1.0" ?>
  -- <imageinfo>
  --    <cells_x>30</cells_x>
  --    <cells_y>21</cells_y>
  --    <segment x1='13' y1='0' x2='16' y2='0' />
  --    <segment x1='13' y1='1' x2='16' y2='1' />
  --    <segment x1='11' y1='2' x2='18' y2='2' />
  --    <segment x1='10' y1='3' x2='18' y2='3' />
  --    <segment x1='10' y1='4' x2='18' y2='4' />
  --    <segment x1='9' y1='5' x2='20' y2='5' />
  --    <segment x1='8' y1='6' x2='20' y2='6' />
  --    <segment x1='8' y1='7' x2='20' y2='7' />
  --    <segment x1='7' y1='8' x2='21' y2='8' />
  --    <segment x1='6' y1='9' x2='21' y2='9' />
  --    <segment x1='5' y1='10' x2='24' y2='10' />
  --    <segment x1='5' y1='11' x2='24' y2='11' />
  --    <segment x1='4' y1='12' x2='25' y2='12' />
  --    <segment x1='3' y1='13' x2='25' y2='13' />
  --    <segment x1='3' y1='14' x2='27' y2='14' />
  --    <segment x1='2' y1='15' x2='27' y2='15' />
  --    <segment x1='1' y1='16' x2='28' y2='16' />
  --  </imageinfo>
  local xmlfilename = string.gsub(filename,"(%..*)$",".xml")
  local mt
  if kpse.filelist[xmlfilename] then
    mt = {}
    local xmltab = load_xml(xmlfilename,"Imageinfo")
    local segments = {}
    local cells_x,cells_y
    for _,v in ipairs(xmltab) do
      if v[".__name"] == "cells_x" then
        cells_x = v[1]
      elseif v[".__name"] == "cells_y" then
        cells_y = v[1]
      elseif v[".__name"] == "segment" then
        -- 0 based segments
        segments[#segments + 1] = {v.x1 + 1,v.y1 + 1,v.x2 + 1,v.y2 + 1}
      end
    end
    -- we have parsed the file, let's build a beautiful 2dim array
    mt.max_x = cells_x
    mt.max_y = cells_y
    for i=1,cells_y do
      mt[i] = {}
      for j=1,cells_x do
        mt[i][j] = 0
      end
    end
    for i,v in ipairs(segments) do
      for x=v[1],v[3] do
        for y=v[2],v[4] do
          mt[y][x] = 1
        end
      end
    end
  end

  if not images[new_name] then
    local image_info = img.scan{filename = filename, pagebox = box, page=page }
    images[new_name] = { img = image_info, allocate = mt }
  end
  return images[new_name]
end

function set_color_if_necessary( nodelist,color )
  if not color then return nodelist end

  local colorname
  if color == -1 then
    colorname = "Schwarz"
  else
    colorname = colortable[color]
  end

  local colstart = node.new(8,39)
  colstart.data  = colors[colorname].pdfstring
  colstart.cmd   = 1
  colstart.stack = 1
  colstart.next = nodelist
  nodelist.prev = colstart

  local colstop  = node.new(8,39)
  colstop.data  = ""
  colstop.cmd   = 2
  colstop.stack = 1
  local last = node.tail(nodelist)
  last.next = colstop
  colstop.prev = last

  return colstart
end

function set_fontfamily_if_necessary(nodelist,fontfamily)
  -- todo: test this FIXME
  -- if fontfamily == 0 then return end
  local fam
  while nodelist do
    if nodelist.id==0 or nodelist.id==1 then
      set_fontfamily_if_necessary(nodelist.list,fontfamily)
    else
      fam = node.has_attribute(nodelist,att_fontfamily)
      if fam == 0 or ( fam == nil and nodelist.id == 2) then
        node.set_attribute(nodelist,att_fontfamily,fontfamily)
      end
    end
    nodelist=nodelist.next
  end
end

function set_sub_supscript( nodelist,script )
  for glyf in node.traverse_id(glyph_node,nodelist) do
    node.set_attribute(glyf,att_script,script)
  end
end

function break_url( nodelist )
  local p

  local slash = string.byte("/")
  for n in node.traverse_id(glyph_node,nodelist) do
    p = node.new(penalty_node)

    if n.char == slash then
      p.penalty=-50
    else
      p.penalty=-5
    end
    p.next = n.next
    n.next = p
    p.prev = n
  end
  return nodelist
end

function colorbar( wd,ht,dp,farbe )
  local colorname = farbe or "Schwarz"
  if not colors[colorname] then
    err("Color %q not found",farbe)
    colorname = "Schwarz"
  end
  local rule_start = node.new("whatsit","pdf_colorstack")
  rule_start.stack = 1
  rule_start.data = colors[colorname].pdfstring
  rule_start.cmd = 1

  local rule = node.new("rule")
  rule.height = ht
  rule.depth  = dp
  rule.width  = wd

  local rule_stop = node.new("whatsit","pdf_colorstack")
  rule_stop.stack = 1
  rule_stop.data = ""
  rule_stop.cmd = 2

  rule_start.next = rule
  rule.next = rule_stop
  rule_stop.prev = rule
  rule.prev = rule_start
  return rule_start, rule_stop
end

--- Rotate a text on a given angle. 
function rotate( nodelist,angle )
  local wd,ht = nodelist.width, nodelist.height + nodelist.depth
  nodelist.width = 0
  nodelist.height = 0
  nodelist.depth = 0
  local angle_rad = math.rad(angle)
  local sin = math.round(math.sin(angle_rad),3)
  local cos = math.round(math.cos(angle_rad),3)
  local q = node.new("whatsit","pdf_literal")
  q.mode = 0
  local shift_x = math.round(math.min(0,math.sin(angle_rad) * sp_to_bp(ht)) + math.min(0,     math.cos(angle_rad) * sp_to_bp(wd)),3)
  local shift_y = math.round(math.max(0,math.sin(angle_rad) * sp_to_bp(wd)) + math.max(0,-1 * math.cos(angle_rad) * sp_to_bp(ht)),3)
  q.data = string.format("q %g %g %g %g %g %g cm",cos,sin, -1 * sin,cos, -1 * shift_x ,-1 * shift_y )
  q.next = nodelist
  local tail = node.tail(nodelist)
  local Q = node.new("whatsit","pdf_literal")
  Q.data = "Q"
  tail.next = Q
  local tmp = node.vpack(q)
  tmp.width  = math.abs(wd * cos) + math.abs(ht * math.cos(math.rad(90 - angle)))
  tmp.height = math.abs(ht * math.sin(math.rad(90 - angle))) + math.abs(wd * sin)
  tmp.depth = 0
  return tmp
end

--- Make a string XML safe
function xml_escape( str )
  local replace = {
    [">"] = "&gt;",
    ["<"] = "&lt;",
    ["\""] = "&quot;",
    ["&"] = "&amp;",
  }
  local ret = str.gsub(str,".",replace)
  return ret
end

--- See `commands#save_dataset()` for  documentation on the data structure for `xml_element`.
function xml_to_string( xml_element, level )
  level = level or 0
  local str = ""
  str = str .. string.rep(" ",level) .. "<" .. xml_element[".__name"]
  for k,v in pairs(xml_element) do
    if type(k) == "string" and not k:match("^%.") then
      str = str .. string.format(" %s=%q", k,v)
    end
  end
  str = str .. ">\n"
  for i,v in ipairs(xml_element) do
    str = str .. xml_to_string(v,level + 1)
  end
  str = str .. string.rep(" ",level) .. "</" .. xml_element[".__name"] .. ">\n"
  return str
end

--- The language name is something like `German` and needs to be mapped to an internal name.
--- 
function get_languagecode( language_name )
  local language_internal = language_mapping[language_name]
  if publisher.languages[language_internal] then
    return publisher.languages[language_internal]
  end
  local filename = string.format("hyph-%s.pat.txt",language_internal)
  log("Loading hyphenation patterns %q.",filename)
  local path = kpse.find_file(filename)
  local pattern_file = io.open(path)
  local pattern = pattern_file:read("*all")

  local l = lang.new()
  l:patterns(pattern)
  local id = l:id()
  log("Language id: %d",id)
  pattern_file:close()
  publisher.languages[language_internal] = id
  return id
end

function set_pageformat( wd,ht )
  options.pagewidth    = wd
  options.seitenhoehe  = ht
  tex.pdfpagewidth =  wd
  tex.pdfpageheight = ht
  -- why the + 2cm? is this for the trim-/art-/bleedbox? FIXME: document
  tex.pdfpagewidth  = tex.pdfpagewidth   + tex.sp("2cm")
  tex.pdfpageheight = tex.pdfpageheight  + tex.sp("2cm")

  -- necessary? FIXME: check if necessary.
  tex.hsize = wd
  tex.vsize = ht
end

--- This function is only called once from `dothings()` during startup phase. We define
--- a family with regular, bold, italic and bolditalic font with size 10pt (we always
--- measure font size in dtp points)
function define_default_fontfamily()
  local fam={
    size         = 10 * factor,
    baselineskip = 12 * factor,
    scriptsize   = 10 * factor * 0.8,
    scriptshift  = 10 * factor * 0.3,
  }
  local ok,tmp
  ok,tmp = fonts.make_font_instance("TeXGyreHeros-Regular",fam.size)
  fam.normal = tmp
  ok,tmp = fonts.make_font_instance("TeXGyreHeros-Regular",fam.scriptsize)
  fam.normalscript = tmp

  ok,tmp = fonts.make_font_instance("TeXGyreHeros-Bold",fam.size)
  fam.bold = tmp
  ok,tmp = fonts.make_font_instance("TeXGyreHeros-Bold",fam.scriptsize)
  fam.boldscript = tmp

  ok,tmp = fonts.make_font_instance("TeXGyreHeros-Italic",fam.size)
  fam.italic = tmp
  ok,tmp = fonts.make_font_instance("TeXGyreHeros-Italic",fam.scriptsize)
  fam.italicscript = tmp

  ok,tmp = fonts.make_font_instance("TeXGyreHeros-BoldItalic",fam.size)
  fam.bolditalic = tmp
  ok,tmp = fonts.make_font_instance("TeXGyreHeros-BoldItalic",fam.scriptsize)
  fam.bolditalicscript = tmp
  fonts.lookup_fontfamily_number_instance[#fonts.lookup_fontfamily_number_instance + 1] = fam
  fonts.lookup_fontfamily_name_number["text"]=#fonts.lookup_fontfamily_number_instance
end


file_end("publisher.lua")
