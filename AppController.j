@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>

// ==============================================================================
// DocNode: Das Model für unsere Baumstruktur
// ==============================================================================
@implementation DocNode : CPObject
{
    CPString _title    @accessors(property=title);
    CPString _type     @accessors(property=type); // "class", "topic", "symbol"
    id       _data     @accessors(property=data); // Das zugrundeliegende JSON-Objekt
    CPArray  _children @accessors(property=children);
    DocNode  _parent   @accessors(property=parent);
}

- (id)initWithTitle:(CPString)aTitle type:(CPString)aType data:(id)aData
{
    self = [super init];
    if (self)
    {
        _title = aTitle;
        _type = aType;
        _data = aData;
        _children = [[CPMutableArray alloc] init];
        _parent = nil;
    }
    return self;
}
@end


// ==============================================================================
// AppController: Der Main Controller der App
// ==============================================================================
@implementation AppController : CPObject
{
    CPWindow        theWindow;
    CPOutlineView   outlineView;
    CPWebView       docWebView;
    
    CPSearchField   searchField;
    CPTextField     _searchStatusLabel;
    CPCheckBox      showPrivateCheckbox;

    CPArray         _allRoots;       // Das Original-Wurzelobjekt
    CPArray         _matchedNodes;   // Die Suchergebnisse
    int             _currentMatchIndex;
    
    BOOL            _showPrivateClasses;
    CPString        _currentSearchTerm;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    theWindow = [[CPWindow alloc] initWithContentRect:CGRectMakeZero() styleMask:CPBorderlessBridgeWindowMask];
    var contentView = [theWindow contentView];
    var bounds = [contentView bounds];

    _showPrivateClasses = NO;
    _currentSearchTerm = @"";
    _matchedNodes = [];
    _currentMatchIndex = -1;

    // 1. Top Bar für die Suche & Filter
    var topBarHeight = 50.0;
    var topBar = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), topBarHeight)];
    [topBar setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [topBar setBackgroundColor:[CPColor colorWithHexString:@"ececec"]];
    
    var searchFieldWidth = 250;
    searchField = [[CPSearchField alloc] initWithFrame:CGRectMake(20, 10, searchFieldWidth, 30)];
    [searchField setPlaceholderString:@"Search full text..."];
    [searchField setTarget:self];
    [searchField setAction:@selector(searchAction:)];
    [topBar addSubview:searchField];
    
    _searchStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 10, 15, 80, 20)];
    [_searchStatusLabel setStringValue:@""];
    [_searchStatusLabel setAlignment:CPRightTextAlignment];
    [topBar addSubview:_searchStatusLabel];

    var prevBtn = [[CPButton alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 100, 13, 30, 24)];
    [prevBtn setTitle:@"<"];
    [prevBtn setTarget:self];
    [prevBtn setAction:@selector(prevMatch:)];
    [topBar addSubview:prevBtn];

    var nextBtn = [[CPButton alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 135, 13, 30, 24)];
    [nextBtn setTitle:@">"];
    [nextBtn setTarget:self];
    [nextBtn setAction:@selector(nextMatch:)];
    [topBar addSubview:nextBtn];
    
    showPrivateCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(20 + searchFieldWidth + 180, 15, 200, 20)];
    [showPrivateCheckbox setTitle:@"Show private classes (_*)"];
    [showPrivateCheckbox setState:CPOffState];
    [showPrivateCheckbox setTarget:self];
    [showPrivateCheckbox setAction:@selector(togglePrivateAction:)];
    [topBar addSubview:showPrivateCheckbox];
    
    [contentView addSubview:topBar];

    // 2. Main Split View (Links: Outline, Rechts: WebView)
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, topBarHeight, CGRectGetWidth(bounds), CGRectGetHeight(bounds) - topBarHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];
    
    // --- Linke Seite: Outline View ---
    var leftScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, 300, CGRectGetHeight([splitView bounds]))];
    [leftScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [leftScroll setAutohidesScrollers:YES];
    
    outlineView = [[CPOutlineView alloc] initWithFrame:[leftScroll bounds]];
    var column = [[CPTableColumn alloc] initWithIdentifier:@"title"];
    [[column headerView] setStringValue:@"Class Hierarchy"];
    [column setWidth:290];
    [outlineView addTableColumn:column];
    [outlineView setOutlineTableColumn:column];
    [outlineView setDataSource:self];
    [outlineView setDelegate:self];
    [leftScroll setDocumentView:outlineView];
    
    [splitView addSubview:leftScroll];

    // --- Rechte Seite: Web View für formatierten Text ---
    var rightView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth([splitView bounds]) - 300, CGRectGetHeight([splitView bounds]))];
    [rightView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    docWebView = [[CPWebView alloc] initWithFrame:[rightView bounds]];
    [docWebView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [rightView addSubview:docWebView];
    
    [splitView addSubview:rightView];
    [contentView addSubview:splitView];

    [theWindow orderFront:self];

    // 3. Daten laden
    _allRoots = [[CPMutableArray alloc] init];
    [self loadDocumentationData];
}

// ==============================================================================
// Data Loading & Tree Building
// ==============================================================================
- (void)loadDocumentationData
{
    var request = [CPURLRequest requestWithURL:"documentation.json"];
    
    [CPURLConnection sendAsynchronousRequest:request queue:[CPOperationQueue mainQueue] completionHandler:function(response, data, error) {
        if (error || !data) {
            CPLog.error("Fehler beim Laden der documentation.json: " + error);
            return;
        }
        
        try {
            var jsonArray = JSON.parse(data);
            [self buildTreeFromJSON:jsonArray];
        } catch (e) {
            CPLog.error("Fehler beim Parsen der JSON: " + e.message);
        }
    }];
}

- (void)buildTreeFromJSON:(JSObject)jsonArray
{
    var classMap = {};
    var allClasses = [];

    for (var i = 0; i < jsonArray.length; i++) {
        var clsData = jsonArray[i];
        var title = (clsData.metadata && clsData.metadata.title) ? clsData.metadata.title : "Unknown Class";
        var clsNode = [[DocNode alloc] initWithTitle:title type:"class" data:clsData];
        
        var topics = clsData.topics || [];
        
        // --- 1. Dedupliziere Symbole innerhalb der Klasse anhand eines Quality-Scores ---
        var uniqueSymbols = {};
        for (var j = 0; j < topics.length; j++) {
            var symbols = topics[j].symbols || [];
            
            for (var k = 0; k < symbols.length; k++) {
                var sym = symbols[k];
                // Schlüsselkombination aus Scope, Name und Kind (sicher gegen Typ-Kollisionen)
                var symKey = (sym.scope || "instance") + "_" + sym.name + "_" + (sym.kind || "symbol");
                
                // Score berechnen (je vollständiger, desto höher der Score)
                var score = 0;
                if (sym.abstract) score += 2;
                if (sym.discussion) score += 2;
                if (sym.declaration) score += 1;
                if (sym.parameters && sym.parameters.length > 0) score += 1;
                if (sym.returnType && sym.returnType !== "void") score += 1;
                
                sym._score = score;
                sym._topicIndex = j; 
                
                var existingSym = uniqueSymbols[symKey];
                // Behalte das Symbol, wenn es neu ist ODER gehaltvoller ist als das bisher gefundene
                if (!existingSym || score > existingSym._score) {
                    uniqueSymbols[symKey] = sym;
                }
            }
        }
        
        // --- 2. Gruppiere die "Gewinner"-Symbole zurück in ihre Topics ---
        var finalTopicsMap = {};
        for (var key in uniqueSymbols) {
            if (uniqueSymbols.hasOwnProperty(key)) {
                var sym = uniqueSymbols[key];
                var tIndex = sym._topicIndex;
                if (!finalTopicsMap[tIndex]) finalTopicsMap[tIndex] = [];
                finalTopicsMap[tIndex].push(sym);
            }
        }
        
        // --- 3. Aufbauen der Tree-Knoten aus den sauberen Symbolen ---
        for (var tIndexStr in finalTopicsMap) {
            if (finalTopicsMap.hasOwnProperty(tIndexStr)) {
                var tIndex = parseInt(tIndexStr, 10);
                var topicData = topics[tIndex];
                var syms = finalTopicsMap[tIndexStr];
                
                if (topicData.title === "General") {
                    // "General" Topic auflösen: Symbole direkt der Klasse unterordnen
                    for (var k = 0; k < syms.length; k++) {
                        var symNode = [[DocNode alloc] initWithTitle:syms[k].name type:"symbol" data:syms[k]];
                        [symNode setParent:clsNode];
                        [[clsNode children] addObject:symNode];
                    }
                } else {
                    var topicNode = [[DocNode alloc] initWithTitle:topicData.title type:"topic" data:topicData];
                    [topicNode setParent:clsNode];
                    [[clsNode children] addObject:topicNode];
                    
                    for (var k = 0; k < syms.length; k++) {
                        var symNode = [[DocNode alloc] initWithTitle:syms[k].name type:"symbol" data:syms[k]];
                        [symNode setParent:topicNode];
                        [[topicNode children] addObject:symNode];
                    }
                }
            }
        }
        
        classMap[title] = clsNode;
        allClasses.push(clsNode);
    }
    
    // 4. CPObject-Wurzel ausfindig machen
    var rootNode = classMap["CPObject"];
    if (!rootNode) {
        rootNode = [[DocNode alloc] initWithTitle:@"CPObject" type:@"class" data:{}];
        classMap["CPObject"] = rootNode;
    }
    
    [_allRoots removeAllObjects];
    [_allRoots addObject:rootNode];
    
    // 5. Hierarchie aufbauen
    for (var i = 0; i < allClasses.length; i++) {
        var clsNode = allClasses[i];
        var title = [clsNode title];
        
        if (title === "CPObject") continue;
        
        var superclass = (clsNode._data.metadata && clsNode._data.metadata.superclass) ? clsNode._data.metadata.superclass : "CPObject";
        var parentNode = classMap[superclass];
        if (!parentNode) parentNode = rootNode;
        
        [clsNode setParent:parentNode];
        [[parentNode children] addObject:clsNode];
    }
    
    [self sortNodesRecursively:_allRoots];
    [outlineView reloadData];
    [outlineView expandItem:rootNode];
}

- (void)sortNodesRecursively:(CPArray)nodes
{
    [nodes sortUsingFunction:function(a, b, ctx) {
        var typeA = [a type];
        var typeB = [b type];
        
        var weightA = (typeA === "class") ? 1 : ((typeA === "topic") ? 2 : 3);
        var weightB = (typeB === "class") ? 1 : ((typeB === "topic") ? 2 : 3);
        
        if (weightA !== weightB) return weightA - weightB;
        
        var titleA = [[a title] lowercaseString];
        var titleB = [[b title] lowercaseString];
        
        if (titleA < titleB) return -1;
        if (titleA > titleB) return 1;
        return 0;
    } context:nil];
    
    for (var i = 0; i < [nodes count]; i++) {
        [self sortNodesRecursively:[nodes[i] children]];
    }
}

// ==============================================================================
// Search Actions
// ==============================================================================
- (void)searchAction:(id)sender
{
    _currentSearchTerm = [[sender stringValue] lowercaseString];
    
    if ([_currentSearchTerm length] === 0) {
        _matchedNodes = [];
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@""];
        return;
    }

    _matchedNodes = [];
    for (var i = 0; i < [_allRoots count]; i++) {
        [self searchInNode:_allRoots[i] forTerm:_currentSearchTerm];
    }

    if ([_matchedNodes count] > 0) {
        _currentMatchIndex = 0;
        [self updateSelectionToCurrentMatch];
    } else {
        _currentMatchIndex = -1;
        [_searchStatusLabel setStringValue:@"0 hits"];
    }
}

- (void)searchInNode:(DocNode)node forTerm:(CPString)term
{
    if (!_showPrivateClasses && [[node title] hasPrefix:@"_"]) return;
    
    var matches = NO;
    if ([[node title] lowercaseString].indexOf(term) !== -1) matches = YES;
    
    if (!matches && [node data]) {
        var d = [node data];
        if (d.abstract && d.abstract.toLowerCase().indexOf(term) !== -1) matches = YES;
        if (d.discussion && d.discussion.toLowerCase().indexOf(term) !== -1) matches = YES;
        if (d.declaration && d.declaration.toLowerCase().indexOf(term) !== -1) matches = YES;
        if (d.primaryContent) {
            if (d.primaryContent.abstract && d.primaryContent.abstract.toLowerCase().indexOf(term) !== -1) matches = YES;
            if (d.primaryContent.discussion && d.primaryContent.discussion.toLowerCase().indexOf(term) !== -1) matches = YES;
            if (d.primaryContent.declaration && d.primaryContent.declaration.toLowerCase().indexOf(term) !== -1) matches = YES;
        }
    }
    
    if (matches) [_matchedNodes addObject:node];
    
    var children = [node children];
    for (var i = 0; i < [children count]; i++) {
        [self searchInNode:children[i] forTerm:term];
    }
}

- (void)prevMatch:(id)sender
{
    if ([_matchedNodes count] === 0) return;
    _currentMatchIndex--;
    if (_currentMatchIndex < 0) _currentMatchIndex = [_matchedNodes count] - 1;
    [self updateSelectionToCurrentMatch];
}

- (void)nextMatch:(id)sender
{
    if ([_matchedNodes count] === 0) return;
    _currentMatchIndex++;
    if (_currentMatchIndex >= [_matchedNodes count]) _currentMatchIndex = 0;
    [self updateSelectionToCurrentMatch];
}

- (void)updateSelectionToCurrentMatch
{
    if ([_matchedNodes count] === 0) return;
    
    var node = _matchedNodes[_currentMatchIndex];
    [_searchStatusLabel setStringValue:(_currentMatchIndex + 1) + @" of " + [_matchedNodes count]];
    
    var p = [node parent];
    var pathToExpand = [];
    while (p) {
        pathToExpand.push(p);
        p = [p parent];
    }
    for (var i = pathToExpand.length - 1; i >= 0; i--) {
        [outlineView expandItem:pathToExpand[i]];
    }
    
    var row = [outlineView rowForItem:node];
    if (row >= 0) {
        [outlineView selectRowIndexes:[CPIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [outlineView scrollRowToVisible:row];
    }
}

- (void)togglePrivateAction:(id)sender
{
    _showPrivateClasses = ([sender state] === CPOnState);
    [outlineView reloadData]; 
    if ([_currentSearchTerm length] > 0) [self searchAction:searchField];
}


// ==============================================================================
// CPOutlineView Data Source & Delegate (dynamischer Filter für Private)
// ==============================================================================
- (CPArray)visibleChildrenOfItem:(DocNode)anItem
{
    var children = (anItem === nil) ? _allRoots : [anItem children];
    if (_showPrivateClasses) return children;
    
    var visible = [];
    for (var i = 0; i < [children count]; i++) {
        if (![[children[i] title] hasPrefix:@"_"]) visible.push(children[i]);
    }
    return visible;
}

- (int)outlineView:(CPOutlineView)anOutlineView numberOfChildrenOfItem:(id)anItem
{
    return [[self visibleChildrenOfItem:anItem] count];
}

- (BOOL)outlineView:(CPOutlineView)anOutlineView isItemExpandable:(id)anItem
{
    return [[self visibleChildrenOfItem:anItem] count] > 0;
}

- (id)outlineView:(CPOutlineView)anOutlineView child:(int)index ofItem:(id)anItem
{
    return [self visibleChildrenOfItem:anItem][index];
}

- (id)outlineView:(CPOutlineView)anOutlineView objectValueForTableColumn:(CPTableColumn)tableColumn byItem:(id)anItem
{
    return [anItem title];
}

- (void)outlineViewSelectionDidChange:(CPNotification)notification
{
    var selectedRow = [outlineView selectedRow];
    if (selectedRow === -1) {
        [docWebView loadHTMLString:@""];
        return;
    }
    
    var selectedItem = [outlineView itemAtRow:selectedRow];
    [self renderHTMLForNode:selectedItem];
}

// ==============================================================================
// HTML Rendering & Doxygen-Tag Cleaner
// ==============================================================================
- (void)renderHTMLForNode:(DocNode)node
{
    try {
        var type = [node type];
        var data = [node data];
        
        if (!data) {
            [docWebView loadHTMLString:"<div style='padding:30px; font-family:sans-serif;'>No data available for this node.</div>"];
            return;
        }
        
        var html = [self htmlHeader];

        if (type === "class") {
            html += "<span class='badge'>" + ((data.metadata && data.metadata.role) ? data.metadata.role.toUpperCase() : "CLASS") + "</span>";
            html += "<h1>" + [node title] + "</h1>";
            
            if (data.metadata) {
                html += "<div class='meta'>Inherits from: " + (data.metadata.superclass || "CPObject") + " &nbsp;|&nbsp; Framework: " + (data.metadata.framework || "Unknown") + "</div>";
            }
            if (data.primaryContent && data.primaryContent.declaration) {
                html += "<h2>Declaration</h2><pre>" + data.primaryContent.declaration + "</pre>";
            }
            if (data.primaryContent && data.primaryContent.abstract) {
                html += "<h2>Overview</h2><div class='discussion'>" + [self cleanText:data.primaryContent.abstract] + "</div>";
            }
            if (data.primaryContent && data.primaryContent.discussion) {
                html += "<h2>Discussion</h2><div class='discussion'>" + [self cleanText:data.primaryContent.discussion] + "</div>";
            }
        } 
        else if (type === "topic") {
            html += "<h1>" + [node title] + "</h1>";
            if (data.abstract) {
                html += "<div class='discussion'>" + [self cleanText:data.abstract] + "</div>";
            }
            
            html += "<h2>Symbols</h2><ul>";
            var kids = [node children];
            for (var i = 0; i < [kids count]; i++) {
                var sym = kids[i];
                html += "<li><strong>" + [sym title] + "</strong>";
                if ([sym data].abstract) html += " - " + [self cleanText:[sym data].abstract];
                html += "</li>";
            }
            html += "</ul>";
        } 
        else if (type === "symbol") {
            html += "<span class='badge'>" + (data.kind || "Symbol").toUpperCase() + "</span>";
            html += "<h1>" + [node title] + "</h1>";
            
            if (data.declaration) {
                html += "<h2>Declaration</h2><pre>" + data.declaration + "</pre>";
            }
            if (data.abstract) {
                html += "<h2>Overview</h2><div class='discussion'>" + [self cleanText:data.abstract] + "</div>";
            }
            if (data.discussion) {
                html += "<h2>Discussion</h2><div class='discussion'>" + [self cleanText:data.discussion] + "</div>";
            }
            if (data.parameters && data.parameters.length > 0) {
                html += "<h2>Parameters</h2><ul>";
                for (var p = 0; p < data.parameters.length; p++) {
                    var param = data.parameters[p];
                    html += "<li><code>" + param.name + "</code> (" + param.type + ")</li>";
                }
                html += "</ul>";
            }
            if (data.returnType && data.returnType !== "void") {
                html += "<h2>Return Value</h2><p>Type: <code>" + data.returnType + "</code></p>";
            }
            if (data.values && data.values.length > 0) {
                html += "<h2>Values</h2><ul>";
                for (var v = 0; v < data.values.length; v++) {
                    var val = data.values[v];
                    html += "<li><code>" + val.name + "</code> = " + val.value + "</li>";
                }
                html += "</ul>";
            }
        }

        html += [self htmlFooter];
        [docWebView loadHTMLString:html];
        
    } catch (err) {
        CPLog.error("Render Error: " + err);
        [docWebView loadHTMLString:"<div style='padding:30px; font-family:sans-serif; color:red;'>Error rendering node: " + err + "</div>"];
    }
}

// Wandelt Doxygen-Tags & Plain-Text in wunderschönes, formatiertes HTML um
- (CPString)cleanText:(CPString)str
{
    if (!str || typeof str !== 'string') return "";
    
    try {
        // Entferne nutzlose Basis-Einrückungen, damit white-space: pre-wrap schön aussieht
        var cleaned = str.replace(/^[ \t]+/gm, '');
        
        // 1. Unnötige Tags unsichtbar machen
        cleaned = cleaned.replace(/@(class|ingroup|brief|details)\s+[^\n]*\n?/gi, '');
        
        // 2. Format \c code word -> <code>code word</code>
        cleaned = cleaned.replace(/\\c\s+([^\s,.;:<]+)/g, "<code>$1</code>");
        
        // 3. Extrahieren und Stylen von Block-Tags. (Matchen bis zum nächsten "@"-Tag oder String-Ende)
        
        // @param name description
        cleaned = cleaned.replace(/@param\s+([a-zA-Z0-9_]+)\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Parameter <code>$1</code>:</span> <span class='tag-desc'>$2</span></div>");
        
        // @return oder @returns
        cleaned = cleaned.replace(/@returns?\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Returns:</span> <span class='tag-desc'>$1</span></div>");
        
        // @throws
        cleaned = cleaned.replace(/@throws\s+([a-zA-Z0-9_]+)\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Throws <code>$1</code>:</span> <span class='tag-desc'>$2</span></div>");

        // @delegate signature \n description
        cleaned = cleaned.replace(/@delegate\s+([^\n]+)\n?([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag delegate-tag'><div class='delegate-sig'><code>$1</code></div><div class='tag-desc'>$2</div></div>");

        // @par title
        cleaned = cleaned.replace(/@par\s+([^\n]+)/g, "<h3 class='doc-par'>$1</h3>");
        
        return cleaned.trim();
    } catch (e) {
        CPLog.error("Error formatting text: " + e);
        return str;
    }
}

- (CPString)htmlHeader
{
    return @"<html><head><style>" +
           @"body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 30px; color: #1d1d1f; line-height: 1.5; }" +
           @"h1 { font-size: 32px; margin-bottom: 5px; font-weight: 600; }" +
           @"h2 { font-size: 22px; border-bottom: 1px solid #d2d2d7; padding-bottom: 8px; margin-top: 35px; font-weight: 600; }" +
           @"pre { background: #f5f5f7; padding: 15px; border-radius: 8px; overflow-x: auto; font-family: 'SF Mono', Consolas, monospace; font-size: 14px; border: 1px solid #d2d2d7; }" +
           @"code { font-family: 'SF Mono', Consolas, monospace; font-size: 13.5px; background: #f0f0f2; padding: 2px 5px; border-radius: 4px; color: #d63384; }" +
           @".badge { display: inline-block; background: #0071e3; color: white; padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: bold; margin-bottom: 10px; letter-spacing: 0.5px; }" +
           @".meta { color: #86868b; font-size: 14px; margin-bottom: 20px; }" +
           @".discussion { white-space: pre-wrap; font-size: 15px; line-height: 1.6; color: #333336; }" +
           @".doc-tag { background: #f5f5f7; padding: 12px 16px; border-radius: 8px; margin-top: 12px; border-left: 4px solid #0071e3; white-space: normal; }" +
           @".delegate-tag { border-left-color: #34c759; }" +
           @".tag-label { font-weight: 600; color: #1d1d1f; display: block; margin-bottom: 6px; font-size: 14px; }" +
           @".tag-desc { color: #515154; font-size: 14px; display: block; margin-top: 4px; white-space: pre-wrap; }" +
           @".delegate-sig { font-family: 'SF Mono', Consolas, monospace; font-size: 13.5px; background: #e5e5ea; padding: 6px 10px; border-radius: 6px; display: inline-block; margin-bottom: 8px; color: #1d1d1f; }" +
           @".doc-par { font-size: 18px; margin-top: 30px; margin-bottom: 10px; padding-bottom: 5px; font-weight: 600; color: #1d1d1f; border-bottom: 1px solid #e5e5ea; }" +
           @"p { font-size: 15px; margin-bottom: 10px; }" +
           @"ul { padding-left: 20px; margin-top: 10px; }" +
           @"li { margin-bottom: 6px; font-size: 15px; }" +
           @"</style></head><body>";
}

- (CPString)htmlFooter
{
    return @"</body></html>";
}

@end
