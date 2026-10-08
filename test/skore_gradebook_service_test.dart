// Tests for issue #148: reading Skore's gradebook as the logged-in teacher
// (`SkoreGradebookService`): the teacher's own gradebooks of a school year,
// and the periods and pupils of one gradebook.
//
// These go through Skore's gradebook RPC service
// (/modules/Skore/backend/gradebook/rpc.php), the one behind /SkoreGradebook:
//   - getNavigation(userID, 0): the tree of the left panel, with the school
//     years;
//   - init(courses, owners, userID, pathIds, 0, 0): the periods and the rows
//     of a gradebook;
//   - getGradebookContext(pathIds, courses, owners, userID, periodId, 0,
//     forcedWy): whether the user may change it.
// The answers below have the shape of trimmed live captures (read-only,
// 2026-10-08) of the developer's gradebooks of 2026-2027 (6EWI, gradebook
// 32508) and, with `wy` "22" in the session object, of 2025-2026 (5BW,
// gradebook 28998). Pupils and teachers are obvious fakes (names, user IDs,
// picture hashes and the base64 in the tooltips); the `colleagues` lists are
// cut to one fake entry. Class, group, model, course, gradebook and period
// IDs and names are Skore's own. Seen live and kept here:
//   - a group node repeats gradebooks of its classes (6DO lists 6WEWI2's);
//   - a class has rows `1.  Last, First` in 2026-2027, `- Last, First` (no
//     class number) in 2025-2026, where some rows carry `gbc_hidden`;
//   - `currentWorkyear` is a string; `wy` "99", a school year Skore does not
//     offer, got `{"navigation": [], "workyears": [...], "currentWorkyear":
//     "99"}`;
//   - getGradebookContext answered `writable` 1 for a closed period of
//     2025-2026 too.
//
// Skore drives the school's grading and reports, and there is no test
// instance: nothing here reaches it. The fake Smartschool fails the test on
// any other RPC method than the three reads, and on any other request than
// the reads of the current user.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smartschool/flutter_smartschool.dart';
import 'package:test/test.dart';

import 'support/no_network.dart';
import 'support/temp_cache_dir.dart';

const _host = 'school.smartschool.be';

class _Credentials extends Credentials {
  @override
  String get username => 'user';
  @override
  String get password => 'pass';
  @override
  String get mainUrl => _host;
  @override
  String? get mfa => 'JBSWY3DPEHPK3PXP';
}

const _rpcPath = '/modules/Skore/backend/gradebook/rpc.php';

/// The logged-in teacher (a fake user ID).
const _me = 1005;

/// Smartschool's start page, where the client reads the logged-in user.
const _startPage =
    '<!DOCTYPE html><html><head><title>Voorbeeldschool</title></head><body>'
    '<script type="text/javascript">\$.extend(true, SMSC, JSON.parse(\'{"vars":'
    '{"authenticatedUser":{"id":"4069_${_me}_0","name":{"startingWithFirstName"'
    ':"Jan Janssens","startingWithLastName":"Janssens Jan"}},"ssID":4069}}\'));'
    '</script></body></html>';

/// Skore's answers (see the top of the file): `getNavigation` of 2026-2027
/// and 2025-2026 (`wy` "22"), `init` and `getGradebookContext` of 6EWI
/// (32508) and 5BW of 2025-2026 (28998).
const _navigationAnswer = r'''
{"result":{"navigation":[{"children":[{"children":[{"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/klas.gif\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;6EWI","raw":"6EWI","icon":"/modules/Skore/themes/default/images/skoreicons/klas.gif","crum":{"path":"3gr D-D/A&#187;6DO&#187;6EWI","ids":["176","472","2440"]},"data":[{"content":"<span><img course=\"2264\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+SmFuc3NlbnMgSmFuPC9saT48L3VsPjwvZGl2Pg==\" encoding=\"base64\">Informaticawetenschappen (2 uur) (6e j DO)</span>","data":{"ownerID":"32508","userID":"1005","classID":"2440","groupID":"472","modelID":"176","courseID":"2264","structureID":"1564"},"coursename":"Informaticawetenschappen (2 uur) (6e j DO)","icon":"PHN2Zy8+","iconType":"svg","part":["Janssens Jan"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"6EWI/Informaticawetenschappen (2 uur)"}]}]}],"structure":["2440","[{\"children\":[],\"courseID\":2264,\"extra\":\"6e j DO\",\"behaviour\":\"\",\"settings\":{\"visibility\":\"visible\",\"count\":\"count\",\"type\":\"course\"},\"coursename\":\"Informaticawetenschappen (2 uur)\"}]"]},{"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/klas.gif\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;6WEWI2","raw":"6WEWI2","icon":"/modules/Skore/themes/default/images/skoreicons/klas.gif","crum":{"path":"3gr D-D/A&#187;6DO&#187;6WEWI2","ids":["176","472","2444"]},"data":[{"content":"<span><img course=\"2264\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+SmFuc3NlbnMgSmFuPC9saT48L3VsPjwvZGl2Pg==\" encoding=\"base64\">Informaticawetenschappen (2 uur) (6e j DO)</span>","data":{"ownerID":"32504","userID":"1005","classID":"2444","groupID":"472","modelID":"176","courseID":"2264","structureID":"1564"},"coursename":"Informaticawetenschappen (2 uur) (6e j DO)","icon":"PHN2Zy8+","iconType":"svg","part":["Janssens Jan"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"6WEWI2/Informaticawetenschappen (2 uur)"}]}]}],"structure":["2444","[{\"children\":[],\"courseID\":2264,\"extra\":\"6e j DO\",\"behaviour\":\"\",\"settings\":{\"visibility\":\"visible\",\"count\":\"count\",\"type\":\"course\"},\"coursename\":\"Informaticawetenschappen (2 uur)\"}]"]}],"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/groep.gif\" border=\"0\" alt=\"mimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;6DO","raw":"6DO","icon":"/modules/Skore/themes/default/images/skoreicons/groep.gif","crum":{"path":"3gr D-D/A&#187;6DO","ids":["176","472"]},"data":[{"content":"<span><img course=\"2264\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+SmFuc3NlbnMgSmFuPC9saT48L3VsPjwvZGl2Pg==\" encoding=\"base64\">Informaticawetenschappen (2 uur) (6e j DO)</span>","data":{"ownerID":"32504","userID":"1005","classID":"2444","groupID":"472","modelID":"176","courseID":"2264","structureID":"1564"},"coursename":"Informaticawetenschappen (2 uur) (6e j DO)","icon":"PHN2Zy8+","iconType":"svg","part":["Janssens Jan"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"6WEWI2/Informaticawetenschappen (2 uur)"}]}]}]},{"children":[{"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/klas.gif\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;5WW1","raw":"5WW1","icon":"/modules/Skore/themes/default/images/skoreicons/klas.gif","crum":{"path":"3gr D-D/A&#187;5DG&#187;5WW1","ids":["176","492","2516"]},"data":[{"content":"<span><img course=\"1588\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+SmFuc3NlbnMgSmFuPC9saT48L3VsPjwvZGl2Pg==\" encoding=\"base64\">Digitale vaardigheden</span>","data":{"ownerID":"34826","userID":"1005","classID":"2516","groupID":"492","modelID":"176","courseID":"1588","structureID":"1564"},"coursename":"Digitale vaardigheden","icon":"PHN2Zy8+","iconType":"svg","part":["Janssens Jan"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"5WW1/Digitale vaardigheden"}]}]},{"content":"<span><img course=\"1840\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+UGVldGVycyBQaWV0PC9saT48bGk+SmFuc3NlbnMgSmFuPC9saT48bGk+RHVwcsOpIEPDqWxpbmU8L2xpPjwvdWw+PC9kaXY+\" encoding=\"base64\">Project 1 (3e graad)</span>","data":{"ownerID":"34582","userID":"1005","classID":"2516","groupID":"492","modelID":"176","courseID":"1840","structureID":"1564"},"coursename":"Project 1 (3e graad)","icon":"PHN2Zy8+","iconType":"svg","part":["Peeters Piet","Janssens Jan","Dupré Céline"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"5WW1/Project 1"}]}]}],"structure":["2516","[{\"children\":[],\"courseID\":1588,\"extra\":\"\",\"behaviour\":\"\",\"settings\":{\"visibility\":\"visible\",\"count\":\"count\",\"type\":\"course\"},\"coursename\":\"Digitale vaardigheden\"},{\"children\":[],\"courseID\":1840,\"extra\":\"3e graad\",\"behaviour\":\"\",\"settings\":{\"visibility\":\"visible\",\"count\":\"count\",\"type\":\"course\"},\"coursename\":\"Project 1\"}]"]}],"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/groep.gif\" border=\"0\" alt=\"mimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;5DG","raw":"5DG","icon":"/modules/Skore/themes/default/images/skoreicons/groep.gif","crum":{"path":"3gr D-D/A&#187;5DG","ids":["176","492"]},"data":[{"content":"<span><img course=\"1840\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+UGVldGVycyBQaWV0PC9saT48bGk+SmFuc3NlbnMgSmFuPC9saT48bGk+RHVwcsOpIEPDqWxpbmU8L2xpPjwvdWw+PC9kaXY+\" encoding=\"base64\">Project 1 (3e graad)</span>","data":{"ownerID":"34582","userID":"1005","classID":"2516","groupID":"492","modelID":"176","courseID":"1840","structureID":"1564"},"coursename":"Project 1 (3e graad)","icon":"PHN2Zy8+","iconType":"svg","part":["Peeters Piet","Janssens Jan","Dupré Céline"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"5WW1/Project 1"}]}]},{"content":"<span><img course=\"1588\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+SmFuc3NlbnMgSmFuPC9saT48L3VsPjwvZGl2Pg==\" encoding=\"base64\">Digitale vaardigheden</span>","data":{"ownerID":"34826","userID":"1005","classID":"2516","groupID":"492","modelID":"176","courseID":"1588","structureID":"1564"},"coursename":"Digitale vaardigheden","icon":"PHN2Zy8+","iconType":"svg","part":["Janssens Jan"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"5WW1/Digitale vaardigheden"}]}]}]}],"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/modellen16.gif\" border=\"0\" alt=\"rootimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;3gr D-D/A","raw":"3gr D-D/A","icon":"/modules/Skore/themes/default/images/skoreicons/modellen16.gif"}],"workyears":[["24","2026-2027"],["22","2025-2026"],["20","2024-2025"]],"currentWorkyear":"24"},"session":1,"method":"getNavigation","timelimit":0,"limitInfo":null}''';

const _navigation22Answer = r'''
{"result":{"navigation":[{"children":[{"children":[{"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/klas.gif\" border=\"0\" alt=\"clsimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;5BW","raw":"5BW","icon":"/modules/Skore/themes/default/images/skoreicons/klas.gif","crum":{"path":"3grD-D/A (ASOTSO)&#187;5DG&#187;5BW","ids":["160","450","2264"]},"data":[{"content":"<span><img course=\"1766\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+SmFuc3NlbnMgSmFuPC9saT48L3VsPjwvZGl2Pg==\" encoding=\"base64\">Informaticawetenschappen (2 uur) (5e j DG)</span>","data":{"ownerID":"28998","userID":"1005","classID":"2264","groupID":"450","modelID":"160","courseID":"1766","structureID":"1564"},"coursename":"Informaticawetenschappen (2 uur) (5e j DG)","icon":"PHN2Zy8+","iconType":"svg","part":["Janssens Jan"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"5BW/Informaticawetenschappen (2 uur)"}]}]}],"structure":["2264","[{\"children\":[],\"courseID\":1766,\"extra\":\"5e j DG\",\"behaviour\":\"\",\"settings\":{\"visibility\":\"visible\",\"count\":\"count\",\"type\":\"course\"},\"coursename\":\"Informaticawetenschappen (2 uur)\"}]"]}],"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/groep.gif\" border=\"0\" alt=\"mimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;5DG","raw":"5DG","icon":"/modules/Skore/themes/default/images/skoreicons/groep.gif","crum":{"path":"3grD-D/A (ASOTSO)&#187;5DG","ids":["160","450"]},"data":[{"content":"<span><img course=\"1766\" src=\"\" selected=\"false\"/></span><span class=\"navigator_course\" skoretooltip=\"true\" tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpsZWZ0Ij5EaXQgdmFrIHdvcmR0IGdlZ2V2ZW4gZG9vcjo8L2Rpdj48ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmxlZnQiPjx1bD48bGk+SmFuc3NlbnMgSmFuPC9saT48L3VsPjwvZGl2Pg==\" encoding=\"base64\">Informaticawetenschappen (2 uur) (5e j DG)</span>","data":{"ownerID":"28998","userID":"1005","classID":"2264","groupID":"450","modelID":"160","courseID":"1766","structureID":"1564"},"coursename":"Informaticawetenschappen (2 uur) (5e j DG)","icon":"PHN2Zy8+","iconType":"svg","part":["Janssens Jan"],"colleagues":[{"id":"1005","userPictureUrl":"/smsc/img/fake/initials_JJ.png","name":"Janssens Jan","shared":[{"userId":"0","ownerId":"0","classcourse":"5BW/Informaticawetenschappen (2 uur)"}]}]}]}],"content":"<img src=\"/modules/Skore/themes/default/images/skoreicons/modellen16.gif\" border=\"0\" alt=\"rootimg\" height=\"16\" width=\"16\" align=\"absmidle\"/>&nbsp;3grD-D/A (ASOTSO)","raw":"3grD-D/A (ASOTSO)","icon":"/modules/Skore/themes/default/images/skoreicons/modellen16.gif"}],"workyears":[["24","2026-2027"],["22","2025-2026"],["20","2024-2025"]],"currentWorkyear":"22"},"session":1,"method":"getNavigation","timelimit":0,"limitInfo":null}''';

const _initAnswer = r'''
{"result":{"left_0":{"orientation":"byColumn","rowHeader":{"sort":["clavg_2440","pupil_1201_2440","pupil_1202_2440","pupil_1203_2440"],"styles":["background:#eeeeee;font-weight:bold;",null,null,null],"classes":[null,"gradebook_odd","gradebook_even","gradebook_odd"]},"colHeader":{"sort":[0]},"stream":[{"c":0,"r":"clavg_2440","v":"6EWI : Klasgemiddelde"},{"c":0,"r":"pupil_1201_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0FBLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5BbiBBZXJ0czwvZGl2PjwvZGl2Pg==\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000001\" alternate=\"QW4gQWVydHM=\">1.  Aerts, An</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1202_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0JDLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5CYXJ0IENsYWVzPC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000002\" alternate=\"QmFydCBDbGFlcw==\">2.  Claes, Bart</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1203_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0NELnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5DaGxvw6kgRHVwb250PC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000003\" alternate=\"Q2hsb8OpIER1cG9udA==\">3.  Dupont, Chloé</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"}]},"left_1":{"orientation":"byColumn","rowHeader":{"sort":["clavg_2440","pupil_1201_2440","pupil_1202_2440","pupil_1203_2440"],"styles":["background:#eeeeee;font-weight:bold;",null,null,null],"classes":[null,"gradebook_odd","gradebook_even","gradebook_odd"]},"colHeader":{"sort":[0]},"stream":[{"c":0,"r":"clavg_2440","v":"6EWI : Klasgemiddelde"},{"c":0,"r":"pupil_1201_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0FBLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5BbiBBZXJ0czwvZGl2PjwvZGl2Pg==\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000001\" alternate=\"QW4gQWVydHM=\">1.  Aerts, An</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1202_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0JDLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5CYXJ0IENsYWVzPC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000002\" alternate=\"QmFydCBDbGFlcw==\">2.  Claes, Bart</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1203_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0NELnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5DaGxvw6kgRHVwb250PC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000003\" alternate=\"Q2hsb8OpIER1cG9udA==\">3.  Dupont, Chloé</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"}]},"left_2":{"orientation":"byColumn","rowHeader":{"sort":["clavg_2440","pupil_1201_2440","pupil_1202_2440","pupil_1203_2440"],"styles":["background:#eeeeee;font-weight:bold;",null,null,null],"classes":[null,"gradebook_odd","gradebook_even","gradebook_odd"]},"colHeader":{"sort":[0]},"stream":[{"c":0,"r":"clavg_2440","v":"6EWI : Klasgemiddelde"},{"c":0,"r":"pupil_1201_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0FBLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5BbiBBZXJ0czwvZGl2PjwvZGl2Pg==\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000001\" alternate=\"QW4gQWVydHM=\">1.  Aerts, An</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1202_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0JDLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5CYXJ0IENsYWVzPC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000002\" alternate=\"QmFydCBDbGFlcw==\">2.  Claes, Bart</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1203_2440","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0NELnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5DaGxvw6kgRHVwb250PC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000003\" alternate=\"Q2hsb8OpIER1cG9udA==\">3.  Dupont, Chloé</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"}]},"periods":[{"name":"DW1","fullname":"DW1","id":"1704","info":"<p><u><b>DW1</b></u></p><p>Open van 2026-09-18 15:30<br/> tot en met 2026-12-18 20:00</p><p>Vul hier je punten voor Dagelijks werk (periode september- oktober) in!</p>","virtual":"0","scope":"1","open":1,"timestamp":"2026-12-18T20:00:00+0100","lockIcon":0,"categoryMode":1}],"reports":[],"activePeriodE":0,"activePeriodP":-1,"activeReport":0,"projectAdmin":1,"classesMap":{"_472":["2440","2442","2444"]},"skoreClasses":{"_2440":"6EWI","_2442":"6WEWI1","_2444":"6WEWI2"},"virtualClasses":null,"coursesMap":{"_2264":"Informaticawetenschappen (2 uur)"},"ownerMap":[{"courseID":"2264","groupID":"472","coursename":"Informaticawetenschappen (2 uur)","ownerID":"32508","classID":"2440"}],"allowEvaluationTypes":null,"wystring":"2026 - 2027","isRestrictedAccess":0},"session":1,"method":"init","timelimit":0,"limitInfo":"Y"}''';

const _init22Answer = r'''
{"result":{"left_0":{"orientation":"byColumn","rowHeader":{"sort":["clavg_2264","pupil_1301_2264","pupil_1302_2264"],"styles":["background:#eeeeee;font-weight:bold;",null,null],"classes":[null,"gradebook_odd","gradebook_even"]},"colHeader":{"sort":[0]},"stream":[{"c":0,"r":"clavg_2264","v":"5BW : Klasgemiddelde"},{"c":0,"r":"pupil_1301_2264","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0xNLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5Mb3R0ZSBNYWVzPC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000004\" alternate=\"TG90dGUgTWFlcw==\">- Maes, Lotte</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1302_2264","v":"<span class=\"gbc_hidden\"  tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0ZWLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5GaWVuIFZlcmJla2U8L2Rpdj48L2Rpdj4=\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000005\" alternate=\"RmllbiBWZXJiZWtl\">- Verbeke, Fien</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"}]},"left_1":{"orientation":"byColumn","rowHeader":{"sort":["clavg_2264","pupil_1301_2264","pupil_1302_2264"],"styles":["background:#eeeeee;font-weight:bold;",null,null],"classes":[null,"gradebook_odd","gradebook_even"]},"colHeader":{"sort":[0]},"stream":[{"c":0,"r":"clavg_2264","v":"5BW : Klasgemiddelde"},{"c":0,"r":"pupil_1301_2264","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0xNLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5Mb3R0ZSBNYWVzPC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000004\" alternate=\"TG90dGUgTWFlcw==\">- Maes, Lotte</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1302_2264","v":"<span class=\"gbc_hidden\"  tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0ZWLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5GaWVuIFZlcmJla2U8L2Rpdj48L2Rpdj4=\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000005\" alternate=\"RmllbiBWZXJiZWtl\">- Verbeke, Fien</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"}]},"left_2":{"orientation":"byColumn","rowHeader":{"sort":["clavg_2264","pupil_1301_2264","pupil_1302_2264"],"styles":["background:#eeeeee;font-weight:bold;",null,null],"classes":[null,"gradebook_odd","gradebook_even"]},"colHeader":{"sort":[0]},"stream":[{"c":0,"r":"clavg_2264","v":"5BW : Klasgemiddelde"},{"c":0,"r":"pupil_1301_2264","v":"<span tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0xNLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5Mb3R0ZSBNYWVzPC9kaXY+PC9kaXY+\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000004\" alternate=\"TG90dGUgTWFlcw==\">- Maes, Lotte</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"},{"c":0,"r":"pupil_1302_2264","v":"<span class=\"gbc_hidden\"  tooltip=\"PGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Ij48aW1nIGNsYXNzPSJwdXBpbF9waWN0dXJlIiBzcmM9Ii9zbXNjL2ltZy9mYWtlL2luaXRpYWxzX0ZWLnBuZyIgLz48ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHg7Ij5GaWVuIFZlcmJla2U8L2Rpdj48L2Rpdj4=\" encoding=\"base64\"  skoretooltip=\"true\" avatarhash=\"4069_00000000-0000-0000-0000-000000000005\" alternate=\"RmllbiBWZXJiZWtl\">- Verbeke, Fien</span><span style=\"position:absolute; right:20px;top:2px;\"></span>"}]},"periods":[{"name":"DW1","fullname":"DW1","id":"1446","info":"<p><u><b>DW1</b></u></p><p><img src=\"/turbowidgets_dev/skore/mvc/templates/images/lock.png\" align=\"absmiddle\"/><span style=\"margin-left:5px;\">Gesloten!</span></p><p>Vul hier je punten voor Dagelijks werk (periode september- oktober) in!</p>","virtual":"0","scope":"1","open":0,"timestamp":"2025-12-18T20:00:00+0100","lockIcon":1,"categoryMode":1},{"name":"DW4","fullname":"DW4","id":"1608","info":"<p><u><b>DW4</b></u></p><p><img src=\"/turbowidgets_dev/skore/mvc/templates/images/lock.png\" align=\"absmiddle\"/><span style=\"margin-left:5px;\">Gesloten!</span></p><p>Vul hier je punten voor Dagelijks werk (periode maart) in!</p>","virtual":"0","scope":"1","open":0,"timestamp":"2026-04-02T23:00:00+0200","lockIcon":1,"categoryMode":1},{"name":"DW5","fullname":"DW5","id":"1610","info":"<p><u><b>DW5</b></u></p><p><img src=\"/turbowidgets_dev/skore/mvc/templates/images/lock.png\" align=\"absmiddle\"/><span style=\"margin-left:5px;\">Gesloten!</span></p><p>Vul hier je punten voor Dagelijks werk (periode april - juni) in!</p>","virtual":"0","scope":"1","open":0,"timestamp":"2026-06-30T00:00:00+0200","lockIcon":1,"categoryMode":1}],"reports":[],"activePeriodE":2,"activePeriodP":-1,"activeReport":0,"projectAdmin":1,"classesMap":{"_450":["2264"]},"skoreClasses":{"_2264":"5BW","_2272":"5WW"},"virtualClasses":null,"coursesMap":{"_1766":"Informaticawetenschappen (2 uur)"},"ownerMap":[{"courseID":"1766","groupID":"450","coursename":"Informaticawetenschappen (2 uur)","ownerID":"28998","classID":"2264"}],"allowEvaluationTypes":null,"wystring":"2026 - 2027","isRestrictedAccess":0},"session":1,"method":"init","timelimit":0,"limitInfo":"Y"}''';

const _contextAnswer = r'''
{"result":{"writable":1,"coordinator":0,"modelId":176,"groupId":472,"classId":2440,"periodId":1704,"courses":[2264],"owners":[32508],"teacherId":1005,"virtualId":0,"restriction":0},"session":1,"method":"getGradebookContext","timelimit":0,"limitInfo":null}''';

const _context22Answer = r'''
{"result":{"writable":1,"coordinator":0,"modelId":160,"groupId":450,"classId":2264,"periodId":1610,"courses":[1766],"owners":[28998],"teacherId":1005,"virtualId":0,"restriction":0},"session":1,"method":"getGradebookContext","timelimit":0,"limitInfo":null}''';

typedef _Answer = ({int status, String body});

_Answer _ok(String body) => (status: 200, body: body);

/// An RPC call as it reached the fake Smartschool.
typedef _Call = ({
  String method,
  List<dynamic> params,
  Map<String, dynamic> session,
  Map<String, String> form,
});

/// A Smartschool whose Skore gradebook answers each RPC method from
/// [answers], by method and by the `wy` of the session object (`null` when
/// it has none); [answers] has the live answers of 2026-2027 and 2025-2026.
class _Smartschool implements HttpClientAdapter {
  _Smartschool([Map<(String, String?), _Answer> replaced = const {}])
    : answers = {
        ('getNavigation', null): _ok(_navigationAnswer),
        ('getNavigation', '24'): _ok(_navigationAnswer),
        ('getNavigation', '22'): _ok(_navigation22Answer),
        ('init', '24'): _ok(_initAnswer),
        ('init', '22'): _ok(_init22Answer),
        ('getGradebookContext', '24'): _ok(_contextAnswer),
        ('getGradebookContext', '22'): _ok(_context22Answer),
        ...replaced,
      };

  final Map<(String, String?), _Answer> answers;

  /// Every RPC call that reached it, in order.
  final List<_Call> calls = [];

  /// Every request that reached it, as `METHOD path` (`RPC <method>` for an
  /// RPC call).
  final List<String> requests = [];

  static ResponseBody _body(String body, {int status = 200, String? type}) =>
      ResponseBody.fromString(
        body,
        status,
        headers: {
          Headers.contentTypeHeader: [type ?? 'text/html; charset=UTF-8'],
        },
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    switch ((options.method, path)) {
      case ('GET', '/'):
        requests.add('GET /');
        return _body(_startPage);
      case ('GET', '/course-list/api/v1/courses'):
        requests.add('GET $path');
        return _body('[{"platformId":4069}]', type: 'application/json');
      case ('POST', _rpcPath):
        final data = options.data;
        final form = {
          for (final e in (data as Map).entries) '${e.key}': '${e.value}',
        };
        final method = form['rpc_method']!;
        // Never let anything else through: only the three reads.
        expect(SkoreGradebookService.rpcMethods, contains(method));
        expect([
          'getNavigation',
          'init',
          'getGradebookContext',
        ], contains(method));
        final session =
            jsonDecode(form['rpc_sessionobj']!) as Map<String, dynamic>;
        calls.add((
          method: method,
          params: jsonDecode(form['rpc_params']!) as List<dynamic>,
          session: session,
          form: form,
        ));
        requests.add('RPC $method');
        final answer = answers[(method, session['wy'] as String?)];
        if (answer == null) {
          fail('No answer for $method with wy ${session['wy']}');
        }
        return _body(
          answer.body,
          status: answer.status,
          type: 'application/json; charset=utf-8',
        );
    }
    fail('Unexpected request: ${options.method} ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

/// A plain [SmartschoolSkoreError]: an answer the service cannot use, not
/// an authentication failure.
Matcher _skoreError([Object? message = anything]) => allOf(
  isNot(isA<SmartschoolAuthenticationError>()),
  isNot(isA<SmartschoolSkoreAccessDeniedError>()),
  isNot(isA<SmartschoolSkoreChangeRefusedError>()),
  isA<SmartschoolSkoreError>().having((e) => e.message, 'message', message),
);

/// The `result` of [answer], an RPC answer above.
dynamic _result(String answer) =>
    (jsonDecode(answer) as Map<String, dynamic>)['result'];

/// [answer] with its `result` changed by [change].
String _withResult(String answer, Object? Function(dynamic result) change) {
  final json = jsonDecode(answer) as Map<String, dynamic>;
  json['result'] = change(json['result']);
  return jsonEncode(json);
}

/// 6EWI's gradebook as `getGradebooks` reads it.
const _ewi = SkoreGradebook(
  gradebookId: 32508,
  teacherId: _me,
  modelId: 176,
  modelName: '3gr D-D/A',
  groupId: 472,
  groupName: '6DO',
  classId: 2440,
  className: '6EWI',
  courseId: 2264,
  courseName: 'Informaticawetenschappen (2 uur) (6e j DO)',
  workyearId: 24,
  teacherNames: ['Janssens Jan'],
);

/// 5BW's gradebook of 2025-2026 as `getGradebooks(workyearId: 22)` reads it.
const _bw = SkoreGradebook(
  gradebookId: 28998,
  teacherId: _me,
  modelId: 160,
  modelName: '3grD-D/A (ASOTSO)',
  groupId: 450,
  groupName: '5DG',
  classId: 2264,
  className: '5BW',
  courseId: 1766,
  courseName: 'Informaticawetenschappen (2 uur) (5e j DG)',
  workyearId: 22,
  teacherNames: ['Janssens Jan'],
);

void main() {
  forbidRealNetwork();

  Future<(_Smartschool, SkoreGradebookService)> serve([
    Map<(String, String?), _Answer> replaced = const {},
  ]) async {
    final client = await SmartschoolClient.create(
      _Credentials(),
      cacheDir: tempCacheDir(),
    );
    addTearDown(client.dispose);
    final server = _Smartschool(replaced);
    client.dio.httpClientAdapter = server;
    return (server, SkoreGradebookService(client));
  }

  // ---------------------------------------------------------------------------
  // The allowlist
  // ---------------------------------------------------------------------------

  group('the methods of the gradebook RPC service', () {
    test('are the reads, nothing else', () {
      expect(SkoreGradebookService.rpcMethods, {
        'getNavigation',
        'init',
        'getGradebookContext',
        'getEvaluations', // #149
      });
      for (final method in SkoreGradebookService.rpcMethods) {
        SkoreGradebookService.checkRpcMethod(method); // does not throw
      }
    });

    test('any other is refused, the publishing and deleting ones too', () {
      const others = [
        'setPublicProp',
        'saveEvalProperties',
        'saveEvaluation',
        'deleteEvaluation',
        'destroyEvaluations',
        'moveEvaluation',
        'copyEvaluation',
        'unhideEvaluations',
        'importWizardResults',
        'saveGrade',
        'saveGradeInfo',
        'usersThatCanAccess',
        'gradebooksToAccess',
        'getGradeInfo',
        '',
        'GETNAVIGATION',
      ];
      for (final method in others) {
        expect(
          () => SkoreGradebookService.checkRpcMethod(method),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.invalidValue, 'invalidValue', method)
                .having((e) => e.message, 'message', contains('nothing was')),
          ),
          reason: method,
        );
        expect(SkoreGradebookService.rpcMethods, isNot(contains(method)));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // The gradebooks of a school year
  // ---------------------------------------------------------------------------

  group('SkoreGradebookService.parseNavigation', () {
    late SkoreGradebookYear year;
    setUpAll(
      () => year = SkoreGradebookService.parseNavigation(
        _result(_navigationAnswer),
      ),
    );

    test('takes the gradebooks of the class nodes, each once, in the order '
        'of the tree', () {
      // 6DO repeats 6WEWI2's gradebook, and 5DG those of 5WW1 (in another
      // order): neither is taken from the group, nor twice.
      expect(year.gradebooks.map((g) => g.gradebookId), [
        32508,
        32504,
        34826,
        34582,
      ]);
    });

    test('gives each gradebook its IDs, path and names', () {
      final ewi = year.gradebooks.first;
      expect(ewi.gradebookId, 32508);
      expect(ewi.teacherId, _me);
      expect(ewi.pathIds, [176, 472, 2440]);
      expect((ewi.modelId, ewi.groupId, ewi.classId), (176, 472, 2440));
      expect(ewi.modelName, '3gr D-D/A');
      expect(ewi.groupName, '6DO');
      expect(ewi.className, '6EWI');
      expect(ewi.courseId, 2264);
      expect(ewi.courseName, 'Informaticawetenschappen (2 uur) (6e j DO)');
      expect(ewi.teacherNames, ['Janssens Jan']);
      expect(ewi.workyearId, 24);

      final project = year.gradebooks.last;
      expect(project.className, '5WW1');
      expect(project.groupName, '5DG');
      expect(project.pathIds, [176, 492, 2516]);
      expect(project.courseName, 'Project 1 (3e graad)');
      expect(project.teacherNames, [
        'Peeters Piet',
        'Janssens Jan',
        'Dupré Céline',
      ]);
    });

    test('gives the school year and the school years Skore offers', () {
      expect(year.workyear.id, 24);
      expect(year.workyear.name, '2026-2027');
      expect(year.workyears.map((y) => (y.id, y.name)), [
        (24, '2026-2027'),
        (22, '2025-2026'),
        (20, '2024-2025'),
      ]);
    });

    test('an earlier school year asked for', () {
      final earlier = SkoreGradebookService.parseNavigation(
        _result(_navigation22Answer),
        workyearId: 22,
      );
      expect(earlier.workyear.name, '2025-2026');
      expect(earlier.gradebooks.map((g) => g.gradebookId), [28998]);
      expect(earlier.gradebooks.single.workyearId, 22);
    });

    test('no gradebooks: an empty list', () {
      final none = SkoreGradebookService.parseNavigation({
        'navigation': <dynamic>[],
        'workyears': [
          ['24', '2026-2027'],
        ],
        'currentWorkyear': 24,
      });
      expect(none.gradebooks, isEmpty);
      expect(none.workyear.id, 24);
    });

    test('a school year Skore does not offer is refused', () {
      // Skore's live answer to wy "99".
      final answer = {
        'navigation': <dynamic>[],
        'workyears': [
          ['24', '2026-2027'],
          ['22', '2025-2026'],
        ],
        'currentWorkyear': '99',
      };
      expect(
        () => SkoreGradebookService.parseNavigation(answer, workyearId: 99),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'workyearId')
              .having((e) => e.message, 'message', contains('22 2025-2026')),
        ),
      );
    });

    test('an answer for another school year than the one asked is refused', () {
      expect(
        () => SkoreGradebookService.parseNavigation(
          _result(_navigationAnswer),
          workyearId: 22,
        ),
        throwsA(_skoreError(contains('instead of 22'))),
      );
    });

    test('a current school year that is not offered is refused', () {
      expect(
        () => SkoreGradebookService.parseNavigation({
          'navigation': <dynamic>[],
          'workyears': [
            ['22', '2025-2026'],
          ],
          'currentWorkyear': '24',
        }),
        throwsA(_skoreError(contains('not among'))),
      );
    });

    test('an unknown shape is refused, never read as no gradebooks', () {
      final navigation = _result(_navigationAnswer) as Map<String, dynamic>;
      final cases = <String, Object?>{
        'not an object': <dynamic>[],
        'no tree': {...navigation}..remove('navigation'),
        'a tree that is not a list': {...navigation, 'navigation': {}},
        'no school years': {...navigation}..remove('workyears'),
        'a school year that is not a pair': {
          ...navigation,
          'workyears': ['24'],
        },
        'no current school year': {...navigation}..remove('currentWorkyear'),
        'a node that is not an object': {
          ...navigation,
          'navigation': ['6EWI'],
        },
        'a class without its list of gradebooks': {
          ...navigation,
          'navigation': [
            {
              'raw': '6EWI',
              'crum': {
                'ids': ['176', '472', '2440'],
              },
            },
          ],
        },
        'a gradebook without its IDs': {
          ...navigation,
          'navigation': [
            {
              'raw': '6EWI',
              'crum': {
                'ids': ['176', '472', '2440'],
              },
              'data': [
                {'coursename': 'Informatica'},
              ],
            },
          ],
        },
        'a gradebook with a non-numeric ID': {
          ...navigation,
          'navigation': [
            {
              'raw': '6EWI',
              'crum': {
                'ids': ['176', '472', '2440'],
              },
              'data': [
                {
                  'data': {
                    'ownerID': 'x',
                    'userID': '1005',
                    'classID': '2440',
                    'groupID': '472',
                    'modelID': '176',
                    'courseID': '2264',
                  },
                },
              ],
            },
          ],
        },
        'children that are not a list': {
          ...navigation,
          'navigation': [
            {'raw': '3gr D-D/A', 'children': 'none'},
          ],
        },
      };
      for (final MapEntry(key: name, value: answer) in cases.entries) {
        expect(
          () => SkoreGradebookService.parseNavigation(answer),
          throwsA(_skoreError()),
          reason: name,
        );
      }
    });
  });

  group('SkoreGradebookService.getGradebooks', () {
    test('reads the current school year with getNavigation(userID, 0), as '
        'the logged-in teacher, without wy', () async {
      final (server, gradebooks) = await serve();

      final books = await gradebooks.getGradebooks();

      expect(books.map((g) => g.gradebookId), [32508, 32504, 34826, 34582]);
      expect(server.calls, hasLength(1));
      final call = server.calls.single;
      expect(call.method, 'getNavigation');
      expect(call.form['rpc_params'], '[$_me,0]');
      expect(call.form['rpc_requestType'], 'requestData');
      expect(call.session.keys, [
        'requestSource',
        'teacher',
        'restriction',
        'timelimit',
        'client_epoch',
      ]);
      expect(call.session['requestSource'], 'skore-web');
      expect(call.session['teacher'], _me);
      expect(call.session['restriction'], 0);
      expect(call.session['timelimit'], isNull);
      expect(call.session['client_epoch'], isA<int>());
      expect(call.session, isNot(contains('wy')));
      // Only the reads of the current user besides it.
      expect(server.requests, [
        'GET /course-list/api/v1/courses',
        'GET /',
        'RPC getNavigation',
      ]);
    });

    test('an earlier school year goes out as wy, a string', () async {
      final (server, gradebooks) = await serve();

      final year = await gradebooks.getGradebookYear(workyearId: 22);

      expect(year.workyear.id, 22);
      expect(year.gradebooks.single.gradebookId, 28998);
      expect(year.gradebooks.single.workyearId, 22);
      final call = server.calls.single;
      expect(call.session['wy'], '22');
      expect(call.session.keys.last, 'wy');
      expect(call.params, [_me, 0]);
    });

    test('a school year ID that is not positive is refused before anything '
        'is sent', () async {
      final (server, gradebooks) = await serve();

      for (final id in [0, -2]) {
        await expectLater(
          gradebooks.getGradebooks(workyearId: id),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'workyearId'),
          ),
        );
      }
      expect(server.requests, isEmpty);
    });

    test('a school year Skore does not offer is refused', () async {
      final (_, gradebooks) = await serve({
        ('getNavigation', '99'): _ok(
          '{"result":{"navigation":[],"workyears":[["24","2026-2027"],'
          '["22","2025-2026"]],"currentWorkyear":"99"},"session":1,'
          '"method":"getNavigation","timelimit":0,"limitInfo":null}',
        ),
      });

      await expectLater(
        gradebooks.getGradebooks(workyearId: 99),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'an answer the service cannot use is a SmartschoolSkoreError',
      () async {
        final cases = <String, _Answer>{
          'HTTP 500': (
            status: 500,
            body: '{"message":"Internal Server Error"}',
          ),
          'an HTML page': _ok(
            '<!DOCTYPE html><html><body><h1>Oeps, er ging iets mis</h1>'
            '</body></html>',
          ),
          'invalid JSON': _ok('{"result":'),
          'no result': _ok('{"session":1}'),
          'a tree that is not a list': _ok(
            '{"result":{"navigation":null,"workyears":[["24","2026-2027"]],'
            '"currentWorkyear":"24"},"session":1}',
          ),
        };
        for (final MapEntry(key: name, value: answer) in cases.entries) {
          final (_, gradebooks) = await serve({
            ('getNavigation', null): answer,
          });
          await expectLater(
            gradebooks.getGradebooks(),
            throwsA(_skoreError()),
            reason: name,
          );
        }
      },
    );

    test('an answer without a session is an expired session', () async {
      final (_, gradebooks) = await serve({
        ('getNavigation', null): _ok('{"result":{},"session":0}'),
      });

      await expectLater(
        gradebooks.getGradebooks(),
        throwsA(isA<SmartschoolSessionExpiredError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // One gradebook
  // ---------------------------------------------------------------------------

  group('SkoreGradebookService.parsePeriods', () {
    test('an open period, with its closing time in UTC', () {
      final periods = SkoreGradebookService.parsePeriods(
        (_result(_initAnswer) as Map)['periods'],
      );
      final dw1 = periods.single;
      expect(dw1.id, 1704);
      expect(dw1.name, 'DW1');
      expect(dw1.fullName, 'DW1');
      expect(dw1.isOpen, isTrue);
      // "2026-12-18T20:00:00+0100"
      expect(dw1.closesAt, DateTime.utc(2026, 12, 18, 19));
      expect(dw1.closesAt!.isUtc, isTrue);
      expect(dw1.info, contains('Open van 2026-09-18 15:30'));
      expect(dw1.categoryMode, 1);
    });

    test('closed periods, also with summer time', () {
      final periods = SkoreGradebookService.parsePeriods(
        (_result(_init22Answer) as Map)['periods'],
      );
      expect(periods.map((p) => p.id), [1446, 1608, 1610]);
      expect(periods.map((p) => p.isOpen), everyElement(isFalse));
      expect(periods.map((p) => p.closesAt), [
        DateTime.utc(2025, 12, 18, 19), // +0100
        DateTime.utc(2026, 4, 2, 21), // +0200
        DateTime.utc(2026, 6, 29, 22), // +0200
      ]);
      expect(periods.first.info, contains('Gesloten!'));
    });

    test('a period without a closing time has none', () {
      final period = SkoreGradebookService.parsePeriods([
        {'id': '9', 'name': 'P', 'open': '1', 'timestamp': ''},
      ]).single;
      expect(period.closesAt, isNull);
      expect(period.isOpen, isTrue);
      expect(period.fullName, 'P');
    });

    test('an unknown shape is refused', () {
      final cases = <String, Object?>{
        'not a list': {'id': '1704'},
        'a period that is not an object': ['DW1'],
        'a period without an ID': [
          {'name': 'DW1', 'open': 1},
        ],
        'a closing time that is no date': [
          {'id': '1704', 'timestamp': '18/12/2026'},
        ],
        'a closing time without its offset': [
          {'id': '1704', 'timestamp': '2026-12-18T20:00:00'},
        ],
      };
      for (final MapEntry(key: name, value: periods) in cases.entries) {
        expect(
          () => SkoreGradebookService.parsePeriods(periods),
          throwsA(_skoreError()),
          reason: name,
        );
      }
    });
  });

  group('SkoreGradebookService.parsePupils', () {
    List<dynamic> stream(String answer) =>
        ((_result(answer) as Map)['left_0'] as Map)['stream'] as List;

    test('the pupils of the class, with their number and names, without the '
        'class average', () {
      final pupils = SkoreGradebookService.parsePupils(
        stream(_initAnswer),
        _ewi,
      );
      expect(pupils.map((p) => p.id), [1201, 1202, 1203]);
      expect(pupils.map((p) => p.classId), everyElement(2440));
      expect(pupils.map((p) => p.number), [1, 2, 3]);
      expect(pupils.map((p) => p.name), [
        'Aerts, An',
        'Claes, Bart',
        'Dupont, Chloé',
      ]);
      // From the base64 `alternate`.
      expect(pupils.map((p) => p.displayName), [
        'An Aerts',
        'Bart Claes',
        'Chloé Dupont',
      ]);
      expect(pupils.map((p) => p.isActive), everyElement(isTrue));
      expect(pupils.first.rowKey, 'pupil_1201_2440');
    });

    test('rows without a class number, and an inactive pupil', () {
      final pupils = SkoreGradebookService.parsePupils(
        stream(_init22Answer),
        _bw,
      );
      expect(pupils.map((p) => p.id), [1301, 1302]);
      expect(pupils.map((p) => p.number), [null, null]);
      expect(pupils.map((p) => p.name), ['Maes, Lotte', 'Verbeke, Fien']);
      expect(pupils.map((p) => p.displayName), ['Lotte Maes', 'Fien Verbeke']);
      expect(pupils.map((p) => p.isActive), [true, false]);
    });

    test('leaves out averages and the rows of other classes, and takes a '
        'pupil once', () {
      final pupils = SkoreGradebookService.parsePupils([
        {'c': 0, 'r': 'clavg_2440', 'v': '6EWI : Klasgemiddelde'},
        {'c': 0, 'r': 'gravg_472', 'v': '6DO : Groepsgemiddelde'},
        {'c': 0, 'r': 'pupil_1201_2440', 'v': '<span>1.  Aerts, An</span>'},
        {'c': 0, 'r': 'pupil_1401_2442', 'v': '<span>1.  Pauwels, Bo</span>'},
        {'c': 0, 'r': 'pupil_1201_2440', 'v': '<span>1.  Aerts, An</span>'},
        {'c': 0, 'r': 'pupil_1202_2440', 'v': '<span>12.  Claes, Bart</span>'},
      ], _ewi);
      expect(pupils.map((p) => p.id), [1201, 1202]);
      expect(pupils.map((p) => p.number), [1, 12]);
      // Without an `alternate`, the name as listed.
      expect(pupils.first.displayName, 'Aerts, An');
      expect(pupils.last.name, 'Claes, Bart');
    });

    test('an unknown shape is refused', () {
      final cases = <String, Object?>{
        'not a list': {'r': 'pupil_1201_2440'},
        'a row that is not an object': ['pupil_1201_2440'],
        'a row key with another shape': [
          {'c': 0, 'r': 'pupil_1201', 'v': '<span>1.  Aerts, An</span>'},
        ],
        'a non-numeric pupil ID': [
          {'c': 0, 'r': 'pupil_x_2440', 'v': '<span>1.  Aerts, An</span>'},
        ],
        'a row without a name': [
          {'c': 0, 'r': 'pupil_1201_2440', 'v': '<span>1.</span>'},
        ],
        'a row without a span': [
          {'c': 0, 'r': 'pupil_1201_2440', 'v': '1.  Aerts, An'},
        ],
      };
      for (final MapEntry(key: name, value: rows) in cases.entries) {
        expect(
          () => SkoreGradebookService.parsePupils(rows, _ewi),
          throwsA(_skoreError()),
          reason: name,
        );
      }
    });
  });

  group('SkoreGradebookService.parseGradebook', () {
    test('a gradebook with its periods, pupils and rights', () {
      final sheet = SkoreGradebookService.parseGradebook(
        _ewi,
        _result(_initAnswer),
        context: _result(_contextAnswer),
      );
      expect(sheet.gradebook, same(_ewi));
      expect(sheet.courseName, 'Informaticawetenschappen (2 uur)');
      expect(sheet.periods.map((p) => p.id), [1704]);
      expect(sheet.activePeriod?.id, 1704);
      expect(sheet.pupils, hasLength(3));
      expect(sheet.writable, isTrue);
      expect(sheet.isCoordinator, isFalse);
    });

    test('the active period is the one at activePeriodE', () {
      final sheet = SkoreGradebookService.parseGradebook(
        _bw,
        _result(_init22Answer),
        context: _result(_context22Answer),
      );
      expect(sheet.activePeriod?.name, 'DW5');
      expect(sheet.writable, isTrue);
    });

    test('an activePeriodE that is not a period: the first', () {
      final sheet = SkoreGradebookService.parseGradebook(
        _bw,
        _result(
          _withResult(_init22Answer, (r) => {...r as Map, 'activePeriodE': 7}),
        ),
        context: _result(_context22Answer),
      );
      expect(sheet.activePeriod?.name, 'DW1');
    });

    test('not writable, and in coordinator mode', () {
      final notWritable = SkoreGradebookService.parseGradebook(
        _ewi,
        _result(_initAnswer),
        context: {...(_result(_contextAnswer) as Map), 'writable': 0},
      );
      expect(notWritable.writable, isFalse);

      final coordinator = SkoreGradebookService.parseGradebook(
        _ewi,
        _result(_initAnswer),
        context: {...(_result(_contextAnswer) as Map), 'coordinator': '1'},
      );
      expect(coordinator.isCoordinator, isTrue);
    });

    test('a gradebook without periods is not writable, and needs no '
        'context', () {
      final sheet = SkoreGradebookService.parseGradebook(_ewi, {
        ...(_result(_initAnswer) as Map),
        'periods': <dynamic>[],
      });
      expect(sheet.periods, isEmpty);
      expect(sheet.activePeriod, isNull);
      expect(sheet.writable, isFalse);
      expect(sheet.pupils, hasLength(3));
    });

    test('an answer about another gradebook, or in an unknown shape, is '
        'refused', () {
      final init = _result(_initAnswer) as Map<String, dynamic>;
      final context = _result(_contextAnswer) as Map<String, dynamic>;
      final cases = <String, (Object?, Object?)>{
        'init not an object': (<dynamic>[], context),
        'no ownerMap': ({...init}..remove('ownerMap'), context),
        'another gradebook in ownerMap': (
          {
            ...init,
            'ownerMap': [
              {'ownerID': '32504', 'classID': '2444', 'coursename': 'X'},
            ],
          },
          context,
        ),
        'the gradebook in another class': (
          {
            ...init,
            'ownerMap': [
              {'ownerID': '32508', 'classID': '2444', 'coursename': 'X'},
            ],
          },
          context,
        ),
        'no periods': ({...init}..remove('periods'), context),
        'no rows': ({...init}..remove('left_0'), context),
        'no context': (init, null),
        'a context of another gradebook': (
          init,
          {
            ...context,
            'owners': [32504],
          },
        ),
        'a context of another class': (init, {...context, 'classId': 2444}),
      };
      for (final MapEntry(key: name, value: (init, context)) in cases.entries) {
        expect(
          () => SkoreGradebookService.parseGradebook(
            _ewi,
            init,
            context: context,
          ),
          throwsA(_skoreError()),
          reason: name,
        );
      }
    });
  });

  group('SkoreGradebookService.getGradebook', () {
    test('sends init and getGradebookContext as the web client does, for the '
        "gradebook's school year", () async {
      final (server, gradebooks) = await serve();

      final sheet = await gradebooks.getGradebook(_ewi);

      expect(sheet.courseName, 'Informaticawetenschappen (2 uur)');
      expect(sheet.periods.single.name, 'DW1');
      expect(sheet.pupils.map((p) => p.name), [
        'Aerts, An',
        'Claes, Bart',
        'Dupont, Chloé',
      ]);
      expect(sheet.writable, isTrue);

      expect(server.calls.map((c) => c.method), [
        'init',
        'getGradebookContext',
      ]);
      // IDs as strings in the lists, the user ID and the period as numbers.
      expect(
        server.calls.first.form['rpc_params'],
        '[["2264"],["32508"],$_me,["176","472","2440"],0,0]',
      );
      expect(
        server.calls.last.form['rpc_params'],
        '[["176","472","2440"],["2264"],["32508"],$_me,1704,0,24]',
      );
      for (final call in server.calls) {
        expect(call.session['teacher'], _me);
        expect(call.session['restriction'], 0);
        expect(call.session['wy'], '24');
      }
    });

    test('a gradebook of an earlier school year', () async {
      final (server, gradebooks) = await serve();

      final books = await gradebooks.getGradebooks(workyearId: 22);
      final sheet = await gradebooks.getGradebook(books.single);

      expect(sheet.periods.map((p) => p.name), ['DW1', 'DW4', 'DW5']);
      expect(sheet.activePeriod?.id, 1610);
      expect(sheet.pupils.map((p) => p.isActive), [true, false]);
      expect(server.calls.map((c) => (c.method, c.session['wy'])), [
        ('getNavigation', '22'),
        ('init', '22'),
        ('getGradebookContext', '22'),
      ]);
      expect(
        server.calls.last.form['rpc_params'],
        '[["160","450","2264"],["1766"],["28998"],$_me,1610,0,22]',
      );
    });

    test('no getGradebookContext for a gradebook without periods', () async {
      final (server, gradebooks) = await serve({
        ('init', '24'): _ok(
          _withResult(_initAnswer, (r) => {...r as Map, 'periods': []}),
        ),
      });

      final sheet = await gradebooks.getGradebook(_ewi);

      expect(sheet.writable, isFalse);
      expect(server.calls.map((c) => c.method), ['init']);
    });

    test('an init answer about another gradebook is refused before the '
        'context is asked', () async {
      final (server, gradebooks) = await serve({
        ('init', '24'): _ok(_init22Answer),
      });

      await expectLater(
        gradebooks.getGradebook(_ewi),
        throwsA(_skoreError(contains('another gradebook'))),
      );
      expect(server.calls.map((c) => c.method), ['init']);
    });

    test(
      'an answer the service cannot use is a SmartschoolSkoreError',
      () async {
        for (final method in ['init', 'getGradebookContext']) {
          final (_, gradebooks) = await serve({
            (method, '24'): (status: 500, body: 'Oeps'),
          });
          await expectLater(
            gradebooks.getGradebook(_ewi),
            throwsA(_skoreError(contains('HTTP 500'))),
            reason: method,
          );
        }
      },
    );
  });
}
