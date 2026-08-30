@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>
@import <Foundation/CPLanguageModel.j>

// ==============================================================================
// DocNode: Model for our documentation tree structure
// ==============================================================================
@implementation DocNode : CPObject
{
    CPString _title    @accessors(property=title);
    CPString _type     @accessors(property=type); // "class", "topic", "symbol"
    id       _data     @accessors(property=data); // Underlying JSON data
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
// AppController: Main Controller
// ==============================================================================
@implementation AppController : CPObject
{
    CPWindow            theWindow;
    CPOutlineView       outlineView;
    CPWebView           docWebView;
    CPScrollView        leftScroll;

    CPSearchField       searchField;
    CPTextField         _searchStatusLabel;
    CPCheckBox          showPrivateCheckbox;
    CPCheckBox          searchTitlesOnlyCheckbox;

    CPArray             _allRoots;       // Root documentation nodes
    CPArray             _matchedNodes;   // Filtered search matches
    int                 _currentMatchIndex;
    
    BOOL                _showPrivateClasses;
    BOOL                _searchTitlesOnly;
    CPString            _currentSearchTerm;
    CPString            _currentHTML;    // Stored right-hand side HTML

    // --- AI Assistant UI Components ---
    CPWindow            _aiAssistantWindow;
    CPTextField         _aiContextLabel;
    CPTextView          _aiPromptTextView;
    CPTextView          _aiResultTextView;
    CPButton            _aiGenerateButton;
    CPButton            _aiCopyButton;
    CPProgressIndicator _aiSpinner;
    CPTextField         _aiStatusLabel;
    CPString            _rawAIResultText;

    // --- AI Settings UI Components ---
    CPWindow            _settingsWindow;
    CPPopUpButton       _servicePopUp;
    CPTextField         _endpointField;
    CPTextField         _modelField;
    CPTextField         _apiKeyField;
    
    CPLanguageModelSession _aiSession;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    // 1. Initialize default AI backend preferences
    var defaults = [CPUserDefaults standardUserDefaults];
    var defaultSettings = [CPDictionary dictionaryWithObjects:[
        @"ollama",
        @"http://localhost:11434/api/generate",
        @"gemma4:e4b",
        @""
    ] forKeys:[
        @"LLMTestServiceType",
        @"LLMTestEndpoint",
        @"LLMTestModel",
        @"LLMTestAPIKey"
    ]];
    [defaults registerDefaults:defaultSettings];

    var activeService = [defaults objectForKey:@"LLMTestServiceType"],
        endpoint      = [defaults objectForKey:@"LLMTestEndpoint"],
        model         = [defaults objectForKey:@"LLMTestModel"],
        apiKey        = [defaults objectForKey:@"LLMTestAPIKey"];

    [CPLanguageModelSession setFallbackServiceType:activeService
                                         endpoint:endpoint
                                            model:model
                                           apiKey:apiKey];

    // 2. Main Window setup
    theWindow = [[CPWindow alloc] initWithContentRect:CGRectMakeZero() styleMask:CPBorderlessBridgeWindowMask];
    
    // Set up global callback for handling hypertext clicks inside CPWebView
    window.appControllerInstance = self;
    window.selectNodeInCappuccino = function(nodeTitle) {
        [window.appControllerInstance selectNodeWithTitle:nodeTitle];
        [[CPRunLoop currentRunLoop] limitDateForMode:CPDefaultRunLoopMode];
    };

    [theWindow orderFront:self];
    
    var contentView = [theWindow contentView];
    var bounds = [contentView bounds];

    _showPrivateClasses = NO;
    _searchTitlesOnly = NO;
    _currentSearchTerm = @"";
    _matchedNodes = [];
    _currentMatchIndex = -1;
    _rawAIResultText = @"";
    _currentHTML = @"";

    // Top Navigation & Control Bar
    var topBarHeight = 50.0;
    var topBar = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), topBarHeight)];
    [topBar setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [topBar setBackgroundColor:[CPColor colorWithHexString:@"ececec"]];
    
    var searchFieldWidth = 220;
    searchField = [[CPSearchField alloc] initWithFrame:CGRectMake(15, 10, searchFieldWidth, 30)];
    [searchField setPlaceholderString:@"Search full text..."];
    [searchField setTarget:self];
    [searchField setAction:@selector(searchAction:)];
    [topBar addSubview:searchField];
    
    searchTitlesOnlyCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(245, 15, 130, 20)];
    [searchTitlesOnlyCheckbox setTitle:@"Titles only"];
    [searchTitlesOnlyCheckbox setState:CPOffState];
    [searchTitlesOnlyCheckbox setTarget:self];
    [searchTitlesOnlyCheckbox setAction:@selector(toggleSearchTitlesOnlyAction:)];
    [topBar addSubview:searchTitlesOnlyCheckbox];

    var prevBtn = [[CPButton alloc] initWithFrame:CGRectMake(380, 13, 26, 24)];
    [prevBtn setTitle:@"<"];
    [prevBtn setTarget:self];
    [prevBtn setAction:@selector(prevMatch:)];
    [topBar addSubview:prevBtn];

    var nextBtn = [[CPButton alloc] initWithFrame:CGRectMake(410, 13, 26, 24)];
    [nextBtn setTitle:@">"];
    [nextBtn setTarget:self];
    [nextBtn setAction:@selector(nextMatch:)];
    [topBar addSubview:nextBtn];
    
    _searchStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(442, 15, 75, 20)];
    [_searchStatusLabel setStringValue:@""];
    [_searchStatusLabel setAlignment:CPLeftTextAlignment];
    [_searchStatusLabel setFont:[CPFont systemFontOfSize:11.0]];
    [topBar addSubview:_searchStatusLabel];

    // Right aligned Action buttons
    var privateCheckboxWidth = 150;
    var privateCheckboxX = CGRectGetWidth(bounds) - privateCheckboxWidth - 15;
    showPrivateCheckbox = [[CPCheckBox alloc] initWithFrame:CGRectMake(privateCheckboxX, 15, privateCheckboxWidth, 20)];
    [showPrivateCheckbox setTitle:@"Show private"];
    [showPrivateCheckbox setState:CPOffState];
    [showPrivateCheckbox setTarget:self];
    [showPrivateCheckbox setAction:@selector(togglePrivateAction:)];
    [showPrivateCheckbox setAutoresizingMask:CPViewMinXMargin];
    [topBar addSubview:showPrivateCheckbox];

    var aiSettingsBtn = [[CPButton alloc] initWithFrame:CGRectMake(privateCheckboxX - 95, 12, 85, 26)];
    [aiSettingsBtn setTitle:@"⚙️ Settings"];
    [aiSettingsBtn setTarget:self];
    [aiSettingsBtn setAction:@selector(openSettingsSheet:)];
    [aiSettingsBtn setAutoresizingMask:CPViewMinXMargin];
    [topBar addSubview:aiSettingsBtn];

    var aiButton = [[CPButton alloc] initWithFrame:CGRectMake(privateCheckboxX - 225, 12, 120, 26)];
    [aiButton setTitle:@"✨ AI Assistant"];
    [aiButton setTarget:self];
    [aiButton setAction:@selector(openAIAssistantSheet:)];
    [aiButton setAutoresizingMask:CPViewMinXMargin];
    [topBar addSubview:aiButton];
    
    [contentView addSubview:topBar];

    // 3. Main Split View (Left: OutlineView, Right: WebView)
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, topBarHeight, CGRectGetWidth(bounds), CGRectGetHeight(bounds) - topBarHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES];
    
    var leftWidth = 300.0;
    leftScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, leftWidth, CGRectGetHeight([splitView bounds]))];
    [leftScroll setAutoresizingMask:CPViewHeightSizable];
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

    var rightView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth([splitView bounds]) - 300, CGRectGetHeight([splitView bounds]))];
    [rightView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

    docWebView = [[CPWebView alloc] initWithFrame:[rightView bounds]];
    [docWebView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [docWebView setScrollMode:CPWebViewScrollNative];
    [rightView addSubview:docWebView];

    [splitView addSubview:rightView];
    [splitView adjustSubviews];
    [contentView addSubview:splitView];

    // Load data
    _allRoots = [[CPMutableArray alloc] init];
    [self loadDocumentationData];
}

- (void)updateWebViewWithHTML:(CPString)html
{
    _currentHTML = html || @"";

    var parentView = [docWebView superview];
    if (parentView)
    {
        var bounds = [parentView bounds];
        [docWebView removeFromSuperview];
        
        docWebView = [[CPWebView alloc] initWithFrame:bounds];
        [docWebView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [docWebView setScrollMode:CPWebViewScrollNative];
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
            CPLog.error("Error loading documentation.json: " + error);
            return;
        }
        
        try {
            var jsonArray = JSON.parse(data);
            [self buildTreeFromJSON:jsonArray];
        } catch (e) {
            CPLog.error("Error parsing JSON: " + e.message);
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
        
        // --- 1. Deduplicate symbols with quality score ---
        var uniqueSymbols = {};
        for (var j = 0; j < topics.length; j++) {
            var symbols = topics[j].symbols || [];
            
            for (var k = 0; k < symbols.length; k++) {
                var sym = symbols[k];
                var symKey = (sym.scope || "instance") + "_" + sym.name + "_" + (sym.kind || "symbol");
                
                var score = 0;
                if (sym.abstract) score += 2;
                if (sym.discussion) score += 2;
                if (sym.declaration) score += 1;
                if (sym.parameters && sym.parameters.length > 0) score += 1;
                if (sym.returnType && sym.returnType !== "void") score += 1;
                
                sym._score = score;
                sym._topicIndex = j; 
                
                var existingSym = uniqueSymbols[symKey];
                if (!existingSym || score > existingSym._score) {
                    uniqueSymbols[symKey] = sym;
                }
            }
        }
        
        // --- 2. Group winning symbols back to topics ---
        var finalTopicsMap = {};
        for (var key in uniqueSymbols) {
            if (uniqueSymbols.hasOwnProperty(key)) {
                var sym = uniqueSymbols[key];
                var tIndex = sym._topicIndex;
                if (!finalTopicsMap[tIndex]) finalTopicsMap[tIndex] = [];
                finalTopicsMap[tIndex].push(sym);
            }
        }
        
        // --- 3. Build tree nodes ---
        for (var tIndexStr in finalTopicsMap) {
            if (finalTopicsMap.hasOwnProperty(tIndexStr)) {
                var tIndex = parseInt(tIndexStr, 10);
                var topicData = topics[tIndex];
                var syms = finalTopicsMap[tIndexStr];
                
                if (topicData.title === "General") {
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
    
    // 4. Root setup
    var rootNode = classMap["CPObject"];
    if (!rootNode) {
        rootNode = [[DocNode alloc] initWithTitle:@"CPObject" type:@"class" data:{}];
        classMap["CPObject"] = rootNode;
    }
    
    [_allRoots removeAllObjects];
    [_allRoots addObject:rootNode];
    
    // 5. Hierarchy
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
    
    var wasAnimates = [outlineView animates];
    [outlineView setAnimates:NO];

    for (var i = pathToExpand.length - 1; i >= 0; i--) {
        [outlineView expandItem:pathToExpand[i]];
    }

    [outlineView setAnimates:wasAnimates];
    
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

- (void)selectNodeWithTitle:(CPString)aTitle
{
    var matchedNode = [self findNodeWithTitle:aTitle inNodes:_allRoots];
    if (matchedNode) {
        var p = [matchedNode parent];
        var pathToExpand = [];
        while (p) {
            pathToExpand.push(p);
            p = [p parent];
        }
        
        var wasAnimates = [outlineView animates];
        [outlineView setAnimates:NO];

        for (var i = pathToExpand.length - 1; i >= 0; i--) {
            [outlineView expandItem:pathToExpand[i]];
        }

        [outlineView setAnimates:wasAnimates];
        
        var row = [outlineView rowForItem:matchedNode];
        if (row >= 0) {
            [outlineView selectRowIndexes:[CPIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
            [outlineView scrollRowToVisible:row];
        }
    }
}

- (DocNode)findNodeWithTitle:(CPString)aTitle inNodes:(CPArray)nodes
{
    for (var i = 0; i < [nodes count]; i++) {
        var node = nodes[i];
        if ([node title] === aTitle) {
            return node;
        }
        var found = [self findNodeWithTitle:aTitle inNodes:[node children]];
        if (found) return found;
    }
    return nil;
}

- (CPString)safeJSString:(CPString)str
{
    if (!str) return @"";
    return encodeURIComponent(str).replace(/'/g, "%27");
}

// ==============================================================================
// CPOutlineView Data Source & Delegate
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
    var icon = "⚪ ";
    var isDep = NO;

    if (type === "class") {
        var isFoundation = YES;
        if (data && data.metadata && data.metadata.framework) {
            isFoundation = (data.metadata.framework === "Foundation");
        } else if (title === "CPObject") {
            isFoundation = YES;
        } else {
            isFoundation = NO;
        }

        icon = isFoundation ? "🔘 " : "🔵 ";

        if (data && data.metadata && data.metadata.deprecated) {
            isDep = YES;
        }
    } else if (type === "topic") {
        icon = "🟢 ";
    } else if (type === "symbol") {
        if (data) {
            if (data.deprecated) {
                isDep = YES;
            }
            if (data.kind === "method") {
                if (data.scope === "class") {
                    icon = "🟠 ";
                } else {
                    icon = "🔴 ";
                }
            } else if (data.kind === "global_variable") {
                icon = "🟡 ";
            } else if (data.kind === "typedef") {
                icon = "🟤 ";
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
// HTML Rendering & Helper Functions
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

        if (type === "class") {
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
                var superclassVal = (data.metadata.superclass || "CPObject");
                var safeSuperclass = [self safeJSString:superclassVal];
                html += "<div class='meta'>Inherits from: <a href=\"javascript:window.parent.selectNodeInCappuccino(decodeURIComponent('" + safeSuperclass + "'))\">" + [self escapeHTML:superclassVal] + "</a> &nbsp;|&nbsp; Framework: " + [self escapeHTML:(frameworkVal || "Unknown")] + "</div>";
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
                    var topicTitle = [topics[i] title];
                    var safeTopic = [self safeJSString:topicTitle];
                    html += "<li><strong><a href=\"javascript:window.parent.selectNodeInCappuccino(decodeURIComponent('" + safeTopic + "'))\">" + [self escapeHTML:topicTitle] + "</a></strong></li>";
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
                    var symTitle = [sym title];
                    var safeSym = [self safeJSString:symTitle];
                    
                    html += "<li" + itemClass + "><span class='badge-inline " + badgeClass + "'>" + [self escapeHTML:badge] + "</span> <strong><a href=\"javascript:window.parent.selectNodeInCappuccino(decodeURIComponent('" + safeSym + "'))\">" + [self escapeHTML:symTitle] + "</a></strong>";
                    if (isSymDep) {
                        html += " <span class='deprecation-inline-badge'>Deprecated</span>";
                    }
                    if (sData.abstract) html += " - " + [self cleanText:sData.abstract];
                    html += "</li>";
                }
                html += "</ul>";
            }
        } 
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
                var symTitle = [sym title];
                var safeSym = [self safeJSString:symTitle];
                
                html += "<li" + itemClass + "><span class='badge-inline " + badgeClass + "'>" + [self escapeHTML:badge] + "</span> <strong><a href=\"javascript:window.parent.selectNodeInCappuccino(decodeURIComponent('" + safeSym + "'))\">" + [self escapeHTML:symTitle] + "</a></strong>";
                if (isSymDep) {
                    html += " <span class='deprecation-inline-badge'>Deprecated</span>";
                }
                if (sData.abstract) html += " - " + [self cleanText:sData.abstract];
                html += "</li>";
            }
            html += "</ul>";
        } 
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
        cleaned = cleaned.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        
        cleaned = cleaned.replace(/&lt;(\/?(?:p|strong|pre|br|code|em|ul|ol|li|b|i|blockquote|span|div|a)\b[^&]*\/?)&gt;/gi, function(match, p1) {
            return "<" + p1.replace(/&quot;/g, '"').replace(/&amp;/g, '&') + ">";
        });

        cleaned = cleaned.replace(/@code\s*([\s\S]*?)\s*@endcode/gi, "<pre><code>$1</code></pre>");
        cleaned = cleaned.replace(/\\c\s+([^\s,.;:]+)/g, "<code>$1</code>");
        
        cleaned = cleaned.replace(/^###\s+([^\n]+)/gm, "<h3>$1</h3>");
        cleaned = cleaned.replace(/^##\s+([^\n]+)/gm, "<h2>$1</h2>");
        cleaned = cleaned.replace(/^#\s+([^\n]+)/gm, "<h1>$1</h1>");

        cleaned = cleaned.replace(/^[-*]\s+([^\n]+)/gm, "<li>$1</li>");
        cleaned = cleaned.replace(/((?:<li>[^\n]+<\/li>\s*)+)/g, "<ul>$1</ul>");

        cleaned = cleaned.replace(/@param\s+([a-zA-Z0-9_]+)\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Parameter <code>$1</code>:</span> <span class='tag-desc'>$2</span></div>");
        
        cleaned = cleaned.replace(/@returns?\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Returns:</span> <span class='tag-desc'>$1</span></div>");
        
        cleaned = cleaned.replace(/@throws\s+([a-zA-Z0-9_]+)\s+([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag'><span class='tag-label'>Throws <code>$1</code>:</span> <span class='tag-desc'>$2</span></div>");

        cleaned = cleaned.replace(/@delegate\s+([^\n]+)\n?([\s\S]*?)(?=\s*@\w+|$)/g, 
            "<div class='doc-tag delegate-tag'><div class='delegate-sig'><code>$1</code></div><div class='tag-desc'>$2</div></div>");

        cleaned = cleaned.replace(/@par\s+([^\n]+)/g, "<h3 class='doc-par'>$1</h3>");

        var parts = cleaned.split(/(<(?:pre|ul|ol|h1|h2|h3|div)[\b>][\s\S]*?<\/\1>)/i);
        for (var i = 0; i < parts.length; i++) {
            if (i % 2 === 0) {
                var text = parts[i];
                text = text.replace(/\r\n/g, '\n');
                text = text.replace(/\n{3,}/g, '\n\n');
                
                var paragraphs = text.split('\n\n');
                for (var p = 0; p < paragraphs.length; p++) {
                    var pText = paragraphs[p].trim();
                    if (pText.length > 0) {
                        pText = pText.replace(/\n/g, ' ');
                        
                        pText = pText.replace(/<a\s+[^>]*>[\s\S]*?<\/a>|<[^>]+>|(https?:\/\/[^\s<]+)/gi, function(match, url) {
                            if (url) {
                                var trailingPunctuation = "";
                                var cleanedUrl = url.replace(/([.,;:?!\)]+)$/, function(punc) {
                                    trailingPunctuation = punc;
                                    return "";
                                });
                                return "<a href='" + cleanedUrl + "' target='_blank'>" + cleanedUrl + "</a>" + trailingPunctuation;
                            }
                            return match;
                        });
                        
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
    return @"<!DOCTYPE html><html><head><meta charset='utf-8'><style>" +
           @"body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 30px; color: #1d1d1f; line-height: 1.5; }" +
           @"h1 { font-size: 32px; margin-bottom: 5px; font-weight: 600; }" +
           @"h2 { font-size: 22px; border-bottom: 1px solid #d2d2d7; padding-bottom: 8px; margin-top: 35px; font-weight: 600; }" +
           @"pre { background: #f5f5f7; padding: 15px; border-radius: 8px; overflow-x: auto; font-family: 'SF Mono', Consolas, monospace; font-size: 14px; border: 1px solid #d2d2d7; }" +
           @"code { font-family: 'SF Mono', Consolas, monospace; font-size: 13.5px; background: #f0f0f2; padding: 2px 5px; border-radius: 4px; color: #d63384; }" +
           @"a { color: #0071e3; text-decoration: none; }" +
           @"a:hover { text-decoration: underline; }" +
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

// ==============================================================================
// AI Context Extraction & Prompt Enrichment
// ==============================================================================
- (DocNode)currentlySelectedNode
{
    var row = [outlineView selectedRow];
    if (row >= 0) {
        return [outlineView itemAtRow:row];
    }
    return nil;
}

// ==============================================================================
// AI Assistant Window & Operations
// ==============================================================================
- (void)openAIAssistantSheet:(id)sender
{
    if (!_aiAssistantWindow)
    {
        _aiAssistantWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 720, 600)
                                                         styleMask:CPTitledWindowMask | CPClosableWindowMask | CPResizableWindowMask];
        [_aiAssistantWindow setTitle:@"✨ Cappuccino AI Assistant"];
        
        var sheetContentView = [_aiAssistantWindow contentView];
        var sheetBounds = [sheetContentView bounds];

        // 1. Context header
        var ctxHeader = [[CPTextField alloc] initWithFrame:CGRectMake(15, 12, 690, 18)];
        [ctxHeader setStringValue:@"Active Documentation Context:"];
        [ctxHeader setFont:[CPFont boldSystemFontOfSize:11.0]];
        [ctxHeader setTextColor:[CPColor darkGrayColor]];
        [sheetContentView addSubview:ctxHeader];

        _aiContextLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 30, CGRectGetWidth(sheetBounds) - 30, 20)];
        [_aiContextLabel setStringValue:@"None"];
        [_aiContextLabel setFont:[CPFont systemFontOfSize:12.0]];
        [_aiContextLabel setAutoresizingMask:CPViewWidthSizable];
        [sheetContentView addSubview:_aiContextLabel];

        // 2. User prompt / Snippet Input area
        var inputLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 55, 690, 18)];
        [inputLabel setStringValue:@"Your Prompt or Code Snippet:"];
        [inputLabel setFont:[CPFont boldSystemFontOfSize:11.0]];
        [inputLabel setTextColor:[CPColor darkGrayColor]];
        [sheetContentView addSubview:inputLabel];

        var promptScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(15, 75, CGRectGetWidth(sheetBounds) - 30, 90)];
        [promptScroll setAutoresizingMask:CPViewWidthSizable];
        [promptScroll setAutohidesScrollers:YES];
        
        _aiPromptTextView = [[CPTextView alloc] initWithFrame:[promptScroll bounds]];
        [_aiPromptTextView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [_aiPromptTextView setEditable:YES];
        [_aiPromptTextView setFont:[CPFont fontWithName:@"SF Mono, Menlo, Consolas, monospace" size:12.0]];
        [_aiPromptTextView setString:@"Please explain this stuff to me."];
        [promptScroll setDocumentView:_aiPromptTextView];
        [sheetContentView addSubview:promptScroll];

        // Action controls
        _aiGenerateButton = [[CPButton alloc] initWithFrame:CGRectMake(15, 172, 190, 28)];
        [_aiGenerateButton setTitle:@"✨ Generate"];
        [_aiGenerateButton setTarget:self];
        [_aiGenerateButton setAction:@selector(runAIGeneration:)];
        [sheetContentView addSubview:_aiGenerateButton];

        _aiSpinner = [[CPProgressIndicator alloc] initWithFrame:CGRectMake(215, 178, 16, 16)];
        [_aiSpinner setStyle:CPProgressIndicatorSpinningStyle];
        [_aiSpinner setControlSize:CPSmallControlSize];
        [_aiSpinner setIndeterminate:YES];
        [sheetContentView addSubview:_aiSpinner];

        _aiStatusLabel = [[CPTextField alloc] initWithFrame:CGRectMake(240, 178, 300, 18)];
        [_aiStatusLabel setStringValue:@""];
        [_aiStatusLabel setFont:[CPFont systemFontOfSize:11.0]];
        [sheetContentView addSubview:_aiStatusLabel];

        // 3. Result / Ready-to-copy code output area
        var resultLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 208, 690, 18)];
        [resultLabel setStringValue:@"AI Generated Code & Explanation (Ready for Copy-Paste):"];
        [resultLabel setFont:[CPFont boldSystemFontOfSize:11.0]];
        [resultLabel setTextColor:[CPColor darkGrayColor]];
        [sheetContentView addSubview:resultLabel];

        var resultScrollHeight = CGRectGetHeight(sheetBounds) - 275;
        var resultScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(15, 228, CGRectGetWidth(sheetBounds) - 30, resultScrollHeight)];
        [resultScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [resultScroll setAutohidesScrollers:YES];

        _aiResultTextView = [[CPTextView alloc] initWithFrame:[resultScroll bounds]];
        [_aiResultTextView setAutoresizingMask:CPViewWidthSizable];
        [_aiResultTextView setEditable:NO];
        [_aiResultTextView setRichText:YES];
        [_aiResultTextView setSelectable:YES];
        [_aiResultTextView setVerticallyResizable:YES];
        [_aiResultTextView setHorizontallyResizable:NO];
        [[_aiResultTextView textContainer] setWidthTracksTextView:YES];
        [_aiResultTextView setFont:[CPFont systemFontOfSize:12.0]];
        [resultScroll setDocumentView:_aiResultTextView];
        [sheetContentView addSubview:resultScroll];

        // Bottom action buttons
        var bottomY = CGRectGetHeight(sheetBounds) - 38;

        _aiCopyButton = [[CPButton alloc] initWithFrame:CGRectMake(15, bottomY, 170, 28)];
        [_aiCopyButton setTitle:@"📋 Copy to Clipboard"];
        [_aiCopyButton setTarget:self];
        [_aiCopyButton setAction:@selector(copyResultToClipboard:)];
        [_aiCopyButton setAutoresizingMask:CPViewMaxXMargin | CPViewMinYMargin];
        [sheetContentView addSubview:_aiCopyButton];

        var closeBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 105, bottomY, 90, 28)];
        [closeBtn setTitle:@"Close"];
        [closeBtn setTarget:self];
        [closeBtn setAction:@selector(closeAIAssistantSheet:)];
        [closeBtn setAutoresizingMask:CPViewMinXMargin | CPViewMinYMargin];
        [sheetContentView addSubview:closeBtn];
    }

    // Refresh context string in label
    var selectedNode = [self currentlySelectedNode];
    if (selectedNode) {
        [_aiContextLabel setStringValue:@"[" + [selectedNode type].toUpperCase() + @"] " + [selectedNode title]];
    } else {
        [_aiContextLabel setStringValue:@"No node selected. Using overall Cappuccino environment."];
    }

    [_aiStatusLabel setStringValue:@""];

    [CPApp beginSheet:_aiAssistantWindow
        modalForWindow:theWindow
         modalDelegate:self
        didEndSelector:nil
           contextInfo:nil];
}

- (void)closeAIAssistantSheet:(id)sender
{
    [CPApp endSheet:_aiAssistantWindow];
    [_aiAssistantWindow orderOut:self];
}

- (void)updateAIResultViewWithMarkdown:(CPString)markdownText
{
    _rawAIResultText = markdownText || @"";

    try {
        var parsedAttrStr = [CPMarkdownParser attributedStringFromMarkdown:_rawAIResultText];
        [_aiResultTextView setEditable:YES];
        [_aiResultTextView setString:@""];
        [_aiResultTextView insertText:parsedAttrStr];
        [_aiResultTextView setEditable:NO];
    }
    catch (e)
    {
        console.error("Markdown parsing failure: ", e);
        [_aiResultTextView setEditable:YES];
        [_aiResultTextView setString:_rawAIResultText];
        [_aiResultTextView setEditable:NO];
    }
}

- (CPString)cleanHTMLForAI:(CPString)html
{
    if (!html || [html length] === 0)
        return @"";

    try {
        var parser = new DOMParser();
        var doc = parser.parseFromString(html, "text/html");

        // 1. Remove head, styles, and scripts
        var unwanted = doc.querySelectorAll("head, style, script");
        for (var i = 0; i < unwanted.length; i++) {
            unwanted[i].parentNode.removeChild(unwanted[i]);
        }

        // 2. Convert headings to markdown
        var headings = doc.querySelectorAll("h1, h2, h3");
        for (var i = 0; i < headings.length; i++) {
            var h = headings[i];
            h.textContent = "\n\n## " + h.textContent.trim() + "\n";
        }

        // 3. Format code blocks
        var pres = doc.querySelectorAll("pre");
        for (var i = 0; i < pres.length; i++) {
            var p = pres[i];
            p.textContent = "\n```\n" + p.textContent.trim() + "\n```\n";
        }

        // 4. Format list items as bullet points
        var listItems = doc.querySelectorAll("li");
        for (var i = 0; i < listItems.length; i++) {
            var li = listItems[i];
            li.textContent = "\n* " + li.textContent.trim();
        }

        // 5. Extract clean text
        var text = doc.body ? (doc.body.innerText || doc.body.textContent) : "";

        // Collapse excess blank lines
        text = text.replace(/\n{3,}/g, "\n\n").trim();
        return text;
    } 
    catch (e) {
        // Fallback regex if DOMParser fails
        return html.replace(/<style[\s\S]*?<\/style>/gi, '')
                   .replace(/<script[\s\S]*?<\/script>/gi, '')
                   .replace(/<[^>]+>/g, ' ')
                   .replace(/\s+/g, ' ')
                   .trim();
    }
}

- (void)runAIGeneration:(id)sender
{
    var userInput = [_aiPromptTextView string];
    if (!userInput || [userInput stringByTrimmingWhitespace] === @"") {
        [_aiStatusLabel setStringValue:@"Please enter a prompt or snippet first."];
        return;
    }

    // Strip HTML into clean structured documentation text
    var cleanContext = [self cleanHTMLForAI:_currentHTML];
    if ([cleanContext length] === 0) {
        cleanContext = @"No documentation currently displayed.";
    }

    var fullPrompt = @"You are an expert Objective-J and Cappuccino framework developer.\n" +
                     @"The user is already an experienced Cappuccino developer.\n\n" +
                     @"GUIDELINES:\n" +
                     @"- Give a concise, direct, high-level summary and practical usage.\n" +
                     @"- Do NOT explain basic language syntax (e.g. do not explain what @implementation or inheritance is).\n" +
                     @"- Do NOT break down class definitions line-by-line.\n" +
                     @"- Start directly with your answer. No preamble or meta-commentary.\n" +
                     @"- Always write valid Objective-J syntax (bracket messaging [receiver msg], never dot-syntax, JS class or C-pointers).\n\n" +
                     @"=== DOCUMENTATION CONTEXT ===\n" +
                     cleanContext + @"\n\n" +
                     @"=== USER REQUEST ===\n" +
                     userInput;

    [_aiGenerateButton setEnabled:NO];
    [_aiSpinner startAnimation:self];
    [_aiStatusLabel setStringValue:@"Generating snippet..."];
    [self updateAIResultViewWithMarkdown:@"Generating response..."];

    if (!_aiSession) {
        _aiSession = [[CPLanguageModelSession alloc] initWithInstructions:@"You are an expert Cappuccino and Objective-J coding assistant. You write concise, idiomatic Objective-J code and clear technical explanations without trivial syntax hand-holding."];
    }

    [_aiSession respondToPrompt:fullPrompt
                        options:nil
              completionHandler:function(finalText, error) {
        [_aiGenerateButton setEnabled:YES];
        [_aiSpinner stopAnimation:self];

        if (error) {
            [_aiStatusLabel setStringValue:@"Generation error."];
            [self updateAIResultViewWithMarkdown:@"Error generating code: " + [error localizedDescription]];
        } else {
            [_aiStatusLabel setStringValue:@"Completed!"];
            [self updateAIResultViewWithMarkdown:finalText];
        }
    }];
}

- (void)copyResultToClipboard:(id)sender
{
    var text = _rawAIResultText || [_aiResultTextView string];
    if (!text || [text length] === 0 || [text isEqualToString:@"Generating response..."]) {
        [_aiStatusLabel setStringValue:@"Nothing to copy."];
        return;
    }

    try {
        if (window.navigator && window.navigator.clipboard && window.navigator.clipboard.writeText) {
            window.navigator.clipboard.writeText(text);
            [_aiStatusLabel setStringValue:@"✅ Copied to clipboard!"];
        } else {
            // Fallback for older browsers
            var tempTextArea = document.createElement("textarea");
            tempTextArea.value = text;
            document.body.appendChild(tempTextArea);
            tempTextArea.select();
            document.execCommand("copy");
            document.body.removeChild(tempTextArea);
            [_aiStatusLabel setStringValue:@"✅ Copied to clipboard!"];
        }
    } catch (e) {
        CPLog.error("Clipboard copy error: " + e);
        [_aiStatusLabel setStringValue:@"Failed to copy to clipboard."];
    }
}

// ==============================================================================
// AI Fallback Settings Sheet
// ==============================================================================
- (void)openSettingsSheet:(id)sender
{
    if (!_settingsWindow)
    {
        _settingsWindow = [[CPWindow alloc] initWithContentRect:CGRectMake(0, 0, 420, 260)
                                                      styleMask:CPTitledWindowMask | CPClosableWindowMask];
        [_settingsWindow setTitle:@"AI Model & Fallback Settings"];
        
        var sheetContentView = [_settingsWindow contentView];
        var sheetBounds = [sheetContentView bounds];

        var serviceLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 25, 110, 20)];
        [serviceLabel setStringValue:@"Service Type:"];
        [serviceLabel setFont:[CPFont systemFontOfSize:12.0]];
        [serviceLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:serviceLabel];

        _servicePopUp = [[CPPopUpButton alloc] initWithFrame:CGRectMake(135, 22, 180, 26) pullsDown:NO];
        [_servicePopUp addItemWithTitle:@"Ollama (Local)"];
        [[_servicePopUp lastItem] setRepresentedObject:@"ollama"];
        [_servicePopUp addItemWithTitle:@"Groq API"];
        [[_servicePopUp lastItem] setRepresentedObject:@"groq"];
        [_servicePopUp addItemWithTitle:@"Google Gemini"];
        [[_servicePopUp lastItem] setRepresentedObject:@"gemini"];
        [_servicePopUp addItemWithTitle:@"OpenRouter"];
        [[_servicePopUp lastItem] setRepresentedObject:@"openrouter"];
        [_servicePopUp setTarget:self];
        [_servicePopUp setAction:@selector(serviceTypeDidChange:)];
        [sheetContentView addSubview:_servicePopUp];

        var endpointLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 67, 110, 20)];
        [endpointLabel setStringValue:@"Endpoint URL:"];
        [endpointLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:endpointLabel];

        _endpointField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 62, CGRectGetWidth(sheetBounds) - 155, 27)];
        [_endpointField setEditable:YES];
        [_endpointField setBezeled:YES];
        [sheetContentView addSubview:_endpointField];

        var modelLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 107, 110, 20)];
        [modelLabel setStringValue:@"Model Name:"];
        [modelLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:modelLabel];

        _modelField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 102, CGRectGetWidth(sheetBounds) - 155, 27)];
        [_modelField setEditable:YES];
        [_modelField setBezeled:YES];
        [sheetContentView addSubview:_modelField];

        var apiKeyLabel = [[CPTextField alloc] initWithFrame:CGRectMake(15, 147, 110, 20)];
        [apiKeyLabel setStringValue:@"API Key:"];
        [apiKeyLabel setAlignment:CPRightTextAlignment];
        [sheetContentView addSubview:apiKeyLabel];

        _apiKeyField = [[CPTextField alloc] initWithFrame:CGRectMake(135, 142, CGRectGetWidth(sheetBounds) - 155, 27)];
        [_apiKeyField setEditable:YES];
        [_apiKeyField setBezeled:YES];
        [_apiKeyField setSecure:YES];
        [sheetContentView addSubview:_apiKeyField];

        var btnY = CGRectGetHeight(sheetBounds) - 45;

        var cancelBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 205, btnY, 90, 26)];
        [cancelBtn setTitle:@"Cancel"];
        [cancelBtn setTarget:self];
        [cancelBtn setAction:@selector(closeSettingsSheet:)];
        [sheetContentView addSubview:cancelBtn];

        var saveBtn = [[CPButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(sheetBounds) - 105, btnY, 90, 26)];
        [saveBtn setTitle:@"Save"];
        [saveBtn setTarget:self];
        [saveBtn setAction:@selector(saveSettings:)];
        [sheetContentView addSubview:saveBtn];
    }

    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [defaults objectForKey:@"LLMTestServiceType"] || @"ollama";

    if (activeService === @"ollama") [_servicePopUp selectItemAtIndex:0];
    else if (activeService === @"groq") [_servicePopUp selectItemAtIndex:1];
    else if (activeService === @"gemini") [_servicePopUp selectItemAtIndex:2];
    else if (activeService === @"openrouter") [_servicePopUp selectItemAtIndex:3];

    [_endpointField setStringValue:[defaults objectForKey:@"LLMTestEndpoint"] || @"http://localhost:11434/api/generate"];
    [_modelField setStringValue:[defaults objectForKey:@"LLMTestModel"] || @"gemma4:e4b"];
    [_apiKeyField setStringValue:[defaults objectForKey:@"LLMTestAPIKey"] || @""];

    [self updateFieldsForService:activeService];

    [CPApp beginSheet:_settingsWindow
        modalForWindow:theWindow
         modalDelegate:self
        didEndSelector:nil
           contextInfo:nil];
}

- (void)updateFieldsForService:(CPString)serviceType
{
    if (serviceType === @"ollama") {
        [_endpointField setEnabled:YES];
        [_apiKeyField setEnabled:NO];
        [_apiKeyField setPlaceholderString:@"Not required"];
    } else {
        [_endpointField setEnabled:NO];
        [_endpointField setPlaceholderString:@"Default platform endpoint used"];
        [_apiKeyField setEnabled:YES];
        [_apiKeyField setPlaceholderString:@"API Token value"];
    }
}

- (void)serviceTypeDidChange:(id)sender
{
    var newService = [[_servicePopUp selectedItem] representedObject];
    [self updateFieldsForService:newService];
}

- (void)closeSettingsSheet:(id)sender
{
    [CPApp endSheet:_settingsWindow];
    [_settingsWindow orderOut:self];
}

- (void)saveSettings:(id)sender
{
    var defaults = [CPUserDefaults standardUserDefaults];
    var activeService = [[_servicePopUp selectedItem] representedObject] || @"ollama";
    var endpoint = [_endpointField stringValue];
    var model = [_modelField stringValue];
    var apiKey = [_apiKeyField stringValue];

    [defaults setObject:activeService forKey:@"LLMTestServiceType"];
    [defaults setObject:endpoint forKey:@"LLMTestEndpoint"];
    [defaults setObject:model forKey:@"LLMTestModel"];
    [defaults setObject:apiKey forKey:@"LLMTestAPIKey"];

    [CPLanguageModelSession setFallbackServiceType:activeService
                                         endpoint:endpoint
                                            model:model
                                           apiKey:apiKey];

    if (_aiSession) {
        [_aiSession destroy];
        _aiSession = nil;
    }

    [self closeSettingsSheet:sender];
}

@end
