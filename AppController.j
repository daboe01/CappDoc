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
    CPCheckBox      searchTitlesOnlyCheckbox;

    CPArray         _allRoots;       // Das Original-Wurzelobjekt
    CPArray         _matchedNodes;   // Die Suchergebnisse
    int             _currentMatchIndex;
    
    BOOL            _showPrivateClasses;
    BOOL            _searchTitlesOnly;
    CPString        _currentSearchTerm;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    theWindow = [[CPWindow alloc] initWithContentRect:CGRectMakeZero() styleMask:CPBorderlessBridgeWindowMask];
    
    // 1. Order the window front first so it scales to the browser viewport
    [theWindow orderFront:self];
    
    var contentView = [theWindow contentView];
    var bounds = [contentView bounds];

    _showPrivateClasses = NO;
    _searchTitlesOnly = NO;
    _currentSearchTerm = @"";
    _matchedNodes = [];
    _currentMatchIndex = -1;

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
    
    searchTitlesOnlyCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(285, 15, 150, 20)];
    [searchTitlesOnlyCheckbox setTitle:@"Search titles only"];
    [searchTitlesOnlyCheckbox setState:CPOffState];
    [searchTitlesOnlyCheckbox setTarget:self];
    [searchTitlesOnlyCheckbox setAction:@selector(toggleSearchTitlesOnlyAction:)];
    [topBar addSubview:searchTitlesOnlyCheckbox];

    var prevBtn = [[CPButton alloc] initWithFrame:CGRectMake(450, 13, 30, 24)];
    [prevBtn setTitle:@"<"];
    [prevBtn setTarget:self];
    [prevBtn setAction:@selector(prevMatch:)];
    [topBar addSubview:prevBtn];

    var nextBtn = [[CPButton alloc] initWithFrame:CGRectMake(485, 13, 30, 24)];
    [nextBtn setTitle:@">"];
    [nextBtn setTarget:self];
    [nextBtn setAction:@selector(nextMatch:)];
    [topBar addSubview:nextBtn];
    
    _searchStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(525, 15, 100, 20)];
    [_searchStatusLabel setStringValue:@""];
    [_searchStatusLabel setAlignment:CPLeftTextAlignment];
    [topBar addSubview:_searchStatusLabel];

    var privateCheckboxWidth = 180;
    var privateCheckboxX = CGRectGetWidth(bounds) - privateCheckboxWidth - 20; // 20px Abstand vom rechten Rand
    
    showPrivateCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(privateCheckboxX, 15, privateCheckboxWidth, 20)];
    [showPrivateCheckbox setTitle:@"Show private classes"];
    [showPrivateCheckbox setState:CPOffState];
    [showPrivateCheckbox setTarget:self];
    [showPrivateCheckbox setAction:@selector(togglePrivateAction:)];
    [showPrivateCheckbox setAutoresizingMask:CPViewMinXMargin]; // Hält das Element rechts beim Skalieren
    [topBar addSubview:showPrivateCheckbox];
    
    [contentView addSubview:topBar];

    // 3. Main Split View (Links: Outline, Rechts: WebView)
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
    [splitView adjustSubviews]; // Force the layout engine to arrange both panes cleanly
    
    [contentView addSubview:splitView];

    // Daten laden
    _allRoots = [[CPMutableArray alloc] init];
    [self loadDocumentationData];
}

// Hilfsmethode, die das WebView bei jedem Klick neu aufbaut, um Browser-iFrame-Glitches zu verhindern
- (void)updateWebViewWithHTML:(CPString)html
{
    var parentView = [docWebView superview];
    if (parentView)
    {
        var frame = [docWebView frame];
        [docWebView removeFromSuperview];
        
        docWebView = [[CPWebView alloc] initWithFrame:frame];
        [docWebView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [parentView addSubview:docWebView];
    }
    
    [docWebView loadHTMLString:html];
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
        
        // Ordnet Subklassen (Type "class") unterhalb von Topics (1) und Symbols (2) ein.
        var weightA = (typeA === "topic") ? 1 : ((typeA === "symbol") ? 2 : 3);
        var weightB = (typeB === "topic") ? 1 : ((typeB === "symbol") ? 2 : 3);
        
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
    
    if (!matches && !_searchTitlesOnly && [node data]) {
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

- (void)toggleSearchTitlesOnlyAction:(id)sender
{
    _searchTitlesOnly = ([sender state] === CPOnState);
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
    var type = [anItem type];
    var title = [anItem title];
    var data = [anItem data];
    var icon = "⚪ "; // Default indicator
    var isDep = NO;

    if (type === "class") {
        // Fallback checks for class framework identification
        var isFoundation = YES;
        if (data && data.metadata && data.metadata.framework) {
            isFoundation = (data.metadata.framework === "Foundation");
        } else if (title === "CPObject") {
            isFoundation = YES;
        } else {
            isFoundation = NO;
        }

        icon = isFoundation ? "🔘 " : "🔵 "; // Foundation: Gray, AppKit: Blue

        if (data && data.metadata && data.metadata.deprecated) {
            isDep = YES;
        }
    } else if (type === "topic") {
        icon = "🟢 "; // Topic
    } else if (type === "symbol") {
        if (data) {
            if (data.deprecated) {
                isDep = YES;
            }
            if (data.kind === "method") {
                if (data.scope === "class") {
                    icon = "🟠 "; // Class Method
                } else {
                    icon = "🔴 "; // Instance Method
                }
            } else if (data.kind === "global_variable") {
                icon = "🟡 "; // Global Variable
            } else if (data.kind === "typedef") {
                icon = "🟤 "; // Typedef
            }
        }
    }

    if (isDep) {
        return icon + title + " (⚠️ Deprecated)";
    }
    return icon + title;
}

- (void)outlineViewSelectionDidChange:(CPNotification)notification
{
    var selectedRow = [outlineView selectedRow];
    if (selectedRow === -1) {
        [self updateWebViewWithHTML:@""];
        return;
    }
    
    var selectedItem = [outlineView itemAtRow:selectedRow];
    [self renderHTMLForNode:selectedItem];
}

// ==============================================================================
// HTML Rendering & Hilfsfunktionen
// ==============================================================================
- (CPString)escapeHTML:(CPString)str
{
    if (!str || typeof str !== 'string') return "";
    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

- (void)renderHTMLForNode:(DocNode)node
{
    try {
        var type = [node type];
        var data = [node data];
        
        if (!data) {
            [self updateWebViewWithHTML:"<div style='padding:30px; font-family:sans-serif;'>No data available for this node.</div>"];
            return;
        }
        
        var html = [self htmlHeader];

        // -----------------------------------------------------------
        // CLASS RENDERER
        // -----------------------------------------------------------
        if (type === "class") {
            // Deprecation Warning
            var classDep = (data.metadata && data.metadata.deprecated) ? data.metadata.deprecated : nil;
            if (classDep) {
                html += "<div class='deprecation-warning'><strong>⚠️ Class Deprecated:</strong> " + [self escapeHTML:classDep] + "</div>";
            }

            var title = [node title];
            var isFoundation = YES;
            if (data.metadata && data.metadata.framework) {
                isFoundation = (data.metadata.framework === "Foundation");
            } else if (title === "CPObject") {
                isFoundation = YES;
            } else {
                isFoundation = NO;
            }

            var badgeClass = isFoundation ? "badge-foundation" : "badge-class";
            var titleStyle = classDep ? " class='deprecated-item'" : "";
            html += "<span class='badge " + badgeClass + "'>" + ((data.metadata && data.metadata.role) ? [self escapeHTML:data.metadata.role].toUpperCase() : "CLASS") + "</span>";
            html += "<h1" + titleStyle + ">" + [self escapeHTML:title] + "</h1>";
            
            if (data.metadata) {
                var frameworkVal = data.metadata.framework;
                if (!frameworkVal && title === "CPObject") {
                    frameworkVal = "Foundation";
                }
                html += "<div class='meta'>Inherits from: " + [self escapeHTML:(data.metadata.superclass || "CPObject")] + " &nbsp;|&nbsp; Framework: " + [self escapeHTML:(frameworkVal || "Unknown")] + "</div>";
            }
            if (data.primaryContent && data.primaryContent.declaration) {
                html += "<h2>Declaration</h2><pre>" + [self escapeHTML:data.primaryContent.declaration] + "</pre>";
            }
            if (data.primaryContent && data.primaryContent.abstract) {
                html += "<h2>Overview</h2><div class='discussion'>" + [self cleanText:data.primaryContent.abstract] + "</div>";
            }
            if (data.primaryContent && data.primaryContent.discussion) {
                html += "<h2>Discussion</h2><div class='discussion'>" + [self cleanText:data.primaryContent.discussion] + "</div>";
            }
            
            // Sammle direkt abhängige Topics & Symbole ("General") zur besseren Übersicht
            var kids = [node children];
            var topics = [];
            var generalSyms = [];
            for (var i = 0; i < [kids count]; i++) {
                if ([kids[i] type] === @"topic") topics.push(kids[i]);
                else if ([kids[i] type] === @"symbol") generalSyms.push(kids[i]);
            }
            
            if (topics.length > 0 || generalSyms.length > 0) {
                html += "<hr style='border:0; border-bottom:1px solid #d2d2d7; margin: 40px 0 20px 0;'/>";
            }
            if (topics.length > 0) {
                html += "<h2>Topics</h2><ul>";
                for (var i = 0; i < topics.length; i++) {
                    html += "<li><strong>" + [self escapeHTML:[topics[i] title]] + "</strong></li>";
                }
                html += "</ul>";
            }
            if (generalSyms.length > 0) {
                html += "<h2>General Symbols</h2><ul>";
                for (var i = 0; i < generalSyms.length; i++) {
                    var sym = generalSyms[i];
                    var sData = [sym data];
                    
                    var badge = (sData.kind || "Symbol").toUpperCase();
                    var badgeClass = "badge-default";
                    if (sData.kind === "method") {
                        if (sData.scope === "class") {
                            badge = "CLASS METHOD";
                            badgeClass = "badge-class-method";
                        } else {
                            badge = "INSTANCE METHOD";
                            badgeClass = "badge-instance-method";
                        }
                    } else if (sData.kind === "global_variable") {
                        badgeClass = "badge-global";
                    } else if (sData.kind === "typedef") {
                        badgeClass = "badge-typedef";
                    }
                    
                    var isSymDep = sData.deprecated;
                    var itemClass = isSymDep ? " class='deprecated-item'" : "";
                    
                    html += "<li" + itemClass + "><span class='badge-inline " + badgeClass + "'>" + [self escapeHTML:badge] + "</span> <strong>" + [self escapeHTML:[sym title]] + "</strong>";
                    if (isSymDep) {
                        html += " <span class='deprecation-inline-badge'>Deprecated</span>";
                    }
                    if (sData.abstract) html += " - " + [self cleanText:sData.abstract];
                    html += "</li>";
                }
                html += "</ul>";
            }
        } 
        
        // -----------------------------------------------------------
        // TOPIC RENDERER
        // -----------------------------------------------------------
        else if (type === "topic") {
            html += "<h1>" + [self escapeHTML:[node title]] + "</h1>";
            if (data.abstract) {
                html += "<div class='discussion'>" + [self cleanText:data.abstract] + "</div>";
            }
            
            html += "<h2>Symbols</h2><ul>";
            var kids = [node children];
            for (var i = 0; i < [kids count]; i++) {
                var sym = kids[i];
                var sData = [sym data];
                
                var badge = (sData.kind || "Symbol").toUpperCase();
                var badgeClass = "badge-default";
                if (sData.kind === "method") {
                    if (sData.scope === "class") {
                        badge = "CLASS METHOD";
                        badgeClass = "badge-class-method";
                    } else {
                        badge = "INSTANCE METHOD";
                        badgeClass = "badge-instance-method";
                    }
                } else if (sData.kind === "global_variable") {
                    badgeClass = "badge-global";
                } else if (sData.kind === "typedef") {
                    badgeClass = "badge-typedef";
                }
                
                var isSymDep = sData.deprecated;
                var itemClass = isSymDep ? " class='deprecated-item'" : "";
                
                html += "<li" + itemClass + "><span class='badge-inline " + badgeClass + "'>" + [self escapeHTML:badge] + "</span> <strong>" + [self escapeHTML:[sym title]] + "</strong>";
                if (isSymDep) {
                    html += " <span class='deprecation-inline-badge'>Deprecated</span>";
                }
                if (sData.abstract) html += " - " + [self cleanText:sData.abstract];
                html += "</li>";
            }
            html += "</ul>";
        } 
        
        // -----------------------------------------------------------
        // SYMBOL RENDERER (Methoden, Global Variables, Typedefs etc.)
        // -----------------------------------------------------------
        else if (type === "symbol") {
            var isDep = data.deprecated;
            if (isDep) {
                html += "<div class='deprecation-warning'><strong>⚠️ Deprecated:</strong> " + [self escapeHTML:data.deprecated] + "</div>";
            }

            var badgeText = (data.kind || "Symbol").toUpperCase();
            var badgeClass = "badge-default";
            if (data.kind === "method") {
                if (data.scope === "class") {
                    badgeText = "CLASS METHOD";
                    badgeClass = "badge-class-method";
                } else {
                    badgeText = "INSTANCE METHOD";
                    badgeClass = "badge-instance-method";
                }
            } else if (data.kind === "global_variable") {
                badgeClass = "badge-global";
            } else if (data.kind === "typedef") {
                badgeClass = "badge-typedef";
            }
            
            html += "<span class='badge " + badgeClass + "'>" + [self escapeHTML:badgeText] + "</span>";
            
            var titleStyle = isDep ? " class='deprecated-item'" : "";
            html += "<h1" + titleStyle + ">" + [self escapeHTML:[node title]] + "</h1>";
            
            if (data.declaration) {
                html += "<h2>Declaration</h2><pre>" + [self escapeHTML:data.declaration] + "</pre>";
            }
            
            // Falls es sich um eine Variable handelt, zeige den Typ explizit an
            if (data.type && data.kind !== "method") {
                html += "<h2>Type</h2><p><code>" + [self escapeHTML:data.type] + "</code></p>";
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
                    html += "<li><code>" + [self escapeHTML:param.name] + "</code> (" + [self escapeHTML:param.type] + ")</li>";
                }
                html += "</ul>";
            }
            
            if (data.returnType && data.returnType !== "void") {
                html += "<h2>Return Value</h2><p>Type: <code>" + [self escapeHTML:data.returnType] + "</code></p>";
            }
            
            if (data.values && data.values.length > 0) {
                html += "<h2>Values</h2><ul>";
                for (var v = 0; v < data.values.length; v++) {
                    var val = data.values[v];
                    var valIsDep = val.deprecated;
                    var valStyle = valIsDep ? " class='deprecated-item'" : "";
                    
                    html += "<li" + valStyle + "><code>" + [self escapeHTML:val.name] + "</code> = " + [self escapeHTML:val.value];
                    if (val.comment) {
                        html += " <span class='comment-text'>// " + [self escapeHTML:val.comment] + "</span>";
                    }
                    if (valIsDep) {
                        html += " <span class='deprecation-inline-badge'>Deprecated</span>";
                    }
                    html += "</li>";
                }
                html += "</ul>";
            }
        }

        html += [self htmlFooter];
        [self updateWebViewWithHTML:html];
        
    } catch (err) {
        CPLog.error("Render Error: " + err);
        [self updateWebViewWithHTML:"<div style='padding:30px; font-family:sans-serif; color:red;'>Error rendering node: " + err + "</div>"];
    }
}

- (CPString)cleanText:(CPString)str
{
    if (!str || typeof str !== 'string') return "";
    
    try {
        var cleaned = str.replace(/^[ \t]+/gm, '');
        cleaned = cleaned.replace(/@(class|ingroup|brief|details|deprecated)\s+[^\n]*\n?/gi, '');
        
        // Escape standard characters
        cleaned = cleaned.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        
        // Selektives Wiederherstellen standardmäßiger Formatierungs-Tags (HTML-Whitelist)
        cleaned = cleaned.replace(/&lt;(\/?(?:p|strong|pre|br|code|em|ul|ol|li|b|i|blockquote|span|div|a)\b[^&]*\/?)&gt;/gi, function(match, p1) {
            return "<" + p1.replace(/&quot;/g, '"').replace(/&amp;/g, '&') + ">";
        });

        // Support für @code ... @endcode blocks
        cleaned = cleaned.replace(/@code\s*([\s\S]*?)\s*@endcode/gi, "<pre><code>$1</code></pre>");

        // Inline-Code Formatierung (\c syntax)
        cleaned = cleaned.replace(/\\c\s+([^\s,.;:]+)/g, "<code>$1</code>");
        
        // Support für Markdown Headings (e.g. ### Title)
        cleaned = cleaned.replace(/^###\s+([^\n]+)/gm, "<h3>$1</h3>");
        cleaned = cleaned.replace(/^##\s+([^\n]+)/gm, "<h2>$1</h2>");
        cleaned = cleaned.replace(/^#\s+([^\n]+)/gm, "<h1>$1</h1>");

        // Support für Markdown Lists (- or *)
        cleaned = cleaned.replace(/^[-*]\s+([^\n]+)/gm, "<li>$1</li>");
        // Consecutive <li> blocks in <ul> wrap
        cleaned = cleaned.replace(/((?:<li>[^\n]+<\/li>\s*)+)/g, "<ul>$1</ul>");

        // @param name description
        cleaned = cleaned.replace(/@param\s+([a-zA-Z0-9_]+)\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Parameter <code>$1</code>:</span> <span class='tag-desc'>$2</span></div>");
        
        // @return oder @returns
        cleaned = cleaned.replace(/@returns?\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Returns:</span> <span class='tag-desc'>$1</span></div>");
        
        // @throws exception description
        cleaned = cleaned.replace(/@throws\s+([a-zA-Z0-9_]+)\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Throws <code>$1</code>:</span> <span class='tag-desc'>$2</span></div>");

        // @delegate signature \n description
        cleaned = cleaned.replace(/@delegate\s+([^\n]+)\n?([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag delegate-tag'><div class='delegate-sig'><code>$1</code></div><div class='tag-desc'>$2</div></div>");

        // @par title
        cleaned = cleaned.replace(/@par\s+([^\n]+)/g, "<h3 class='doc-par'>$1</h3>");

        // --- Paragraph processing & Silly newline cleanup ---
        // Isolates structural blocks so we don't accidentally wrap pre, lists, or headers inside <p> tags
        var parts = cleaned.split(/(<(?:pre|ul|ol|h1|h2|h3|div)[\b>][\s\S]*?<\/\1>)/i);
        for (var i = 0; i < parts.length; i++) {
            if (i % 2 === 0) { // Plain text content blocks
                var text = parts[i];
                text = text.replace(/\r\n/g, '\n');
                text = text.replace(/\n{3,}/g, '\n\n'); // normalize multiple newlines
                
                var paragraphs = text.split('\n\n');
                for (var p = 0; p < paragraphs.length; p++) {
                    var pText = paragraphs[p].trim();
                    if (pText.length > 0) {
                        pText = pText.replace(/\n/g, ' '); // Convert single newlines to spaces to collapse hard wraps
                        
                        // Parse and format @note tags into elegant callouts
                        if (/^@note/i.test(pText)) {
                            pText = pText.replace(/^@note\s+/i, "");
                            paragraphs[p] = "<div class='doc-note'><strong>Note:</strong> " + pText + "</div>";
                        } else {
                            paragraphs[p] = "<p>" + pText + "</p>";
                        }
                    } else {
                        paragraphs[p] = "";
                    }
                }
                parts[i] = paragraphs.join("");
            }
        }
        cleaned = parts.join("");
        
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
           @".badge { display: inline-block; color: white; padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: bold; margin-bottom: 10px; letter-spacing: 0.5px; }" +
           @".badge-inline { display: inline-block; color: white; padding: 2px 6px; border-radius: 6px; font-size: 10px; font-weight: bold; margin-right: 5px; letter-spacing: 0.5px; vertical-align: middle; }" +
           @".badge-class { background: #0071e3; }" +
           @".badge-foundation { background: #8e8e93; }" +
           @".badge-instance-method { background: #ff3b30; }" +
           @".badge-class-method { background: #ff9500; }" +
           @".badge-global { background: #ffcc00; color: #1d1d1f; }" +
           @".badge-typedef { background: #a2845e; }" +
           @".badge-default { background: #8e8e93; }" +
           @".meta { color: #86868b; font-size: 14px; margin-bottom: 20px; }" +
           @".discussion { font-size: 15px; line-height: 1.65; color: #333336; }" +
           @".discussion p { margin-top: 0; margin-bottom: 16px; }" +
           @".discussion p:last-child { margin-bottom: 0; }" +
           @".doc-note { background: #f5f5f7; border-left: 4px solid #8e8e93; color: #1d1d1f; padding: 12px 16px; border-radius: 8px; margin: 18px 0; font-size: 14.5px; line-height: 1.6; }" +
           @".doc-note strong { color: #1d1d1f; font-weight: 600; }" +
           @".doc-tag { background: #f5f5f7; padding: 12px 16px; border-radius: 8px; margin-top: 12px; border-left: 4px solid #0071e3; white-space: normal; }" +
           @".delegate-tag { border-left-color: #34c759; }" +
           @".tag-label { font-weight: 600; color: #1d1d1f; display: block; margin-bottom: 6px; font-size: 14px; }" +
           @".tag-desc { color: #515154; font-size: 14px; display: block; margin-top: 4px; white-space: pre-wrap; }" +
           @".delegate-sig { font-family: 'SF Mono', Consolas, monospace; font-size: 13.5px; background: #e5e5ea; padding: 6px 10px; border-radius: 6px; display: inline-block; margin-bottom: 8px; color: #1d1d1f; }" +
           @".doc-par { font-size: 18px; margin-top: 30px; margin-bottom: 10px; padding-bottom: 5px; font-weight: 600; color: #1d1d1f; border-bottom: 1px solid #e5e5ea; }" +
           @"p { font-size: 15px; margin-bottom: 10px; }" +
           @"ul { padding-left: 20px; margin-top: 10px; }" +
           @"li { margin-bottom: 6px; font-size: 15px; }" +
           @".deprecation-warning { background: #fff3cd; border-left: 4px solid #ffc107; color: #664d03; padding: 12px 16px; border-radius: 8px; margin-bottom: 20px; font-size: 14px; }" +
           @".deprecation-warning strong { color: #2b2000; }" +
           @".deprecated-item { text-decoration: line-through; color: #86868b !important; }" +
           @".deprecation-inline-badge { background-color: #f8d7da; color: #842029; font-size: 11px; padding: 2px 6px; border-radius: 4px; font-weight: bold; margin-left: 8px; display: inline-block; vertical-align: middle; }" +
           @".comment-text { color: #86868b; font-size: 13px; font-family: 'SF Mono', Consolas, monospace; }" +
           @"</style></head><body>";
}

- (CPString)htmlFooter
{
    return @"</body></html>";
}

@end
