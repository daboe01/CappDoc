@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>

// ==============================================================================
// DocNode: Ein einfaches Model für unsere Baumstruktur (Klassen -> Topics -> Symbole)
// ==============================================================================
@implementation DocNode : CPObject
{
    CPString _title    @accessors(property=title);
    CPString _type     @accessors(property=type); // "class", "topic", "symbol"
    id       _data     @accessors(property=data); // Das zugrundeliegende JSON-Objekt
    CPArray  _children @accessors(property=children);
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

    CPArray         _allRoots;       // Alle geladenen Daten
    CPArray         _displayedRoots; // Aktuell gefilterte Daten
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    theWindow = [[CPWindow alloc] initWithContentRect:CGRectMakeZero() styleMask:CPBorderlessBridgeWindowMask];
    var contentView = [theWindow contentView];
    var bounds = [contentView bounds];

    // 1. Top Bar für die Suche
    var topBarHeight = 50.0;
    var topBar = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(bounds), topBarHeight)];
    [topBar setAutoresizingMask:CPViewWidthSizable | CPViewMaxYMargin];
    [topBar setBackgroundColor:[CPColor colorWithHexString:@"ececec"]];
    
    searchField = [[CPSearchField alloc] initWithFrame:CGRectMake(20, 10, 300, 30)];
    [searchField setPlaceholderString:@"Search symbols, classes, topics..."];
    [searchField setTarget:self];
    [searchField setAction:@selector(searchAction:)];
    [topBar addSubview:searchField];
    
    [contentView addSubview:topBar];

    // 2. Main Split View (Links: Outline, Rechts: Content)
    var splitView = [[CPSplitView alloc] initWithFrame:CGRectMake(0, topBarHeight, CGRectGetWidth(bounds), CGRectGetHeight(bounds) - topBarHeight)];
    [splitView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [splitView setVertical:YES]; // Vertikaler Splitter (Links/Rechts)
    
    // --- Linke Seite: Outline View ---
    var leftScroll = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, 300, CGRectGetHeight([splitView bounds]))];
    [leftScroll setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [leftScroll setAutohidesScrollers:YES];
    
    outlineView = [[CPOutlineView alloc] initWithFrame:[leftScroll bounds]];
    var column = [[CPTableColumn alloc] initWithIdentifier:@"title"];
    [[column headerView] setStringValue:@"Documentation"];
    [column setWidth:290];
    [outlineView addTableColumn:column];
    [outlineView setOutlineTableColumn:column];
    [outlineView setDataSource:self];
    [outlineView setDelegate:self];
    [leftScroll setDocumentView:outlineView];
    
    [splitView addSubview:leftScroll];

    // --- Rechte Seite: Web View für formatierten Text ---
    var rightView = [[CPView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth([splitView bounds]) - 300, CGRectGetHeight([splitView bounds]))];
    docWebView = [[CPWebView alloc] initWithFrame:[rightView bounds]];
    [docWebView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
    [rightView addSubview:docWebView];
    
    [splitView addSubview:rightView];
    [contentView addSubview:splitView];

    [theWindow orderFront:self];

    // 3. Daten laden
    _allRoots = [];
    _displayedRoots = [];
    [self loadDocumentationData];
}

// ==============================================================================
// Data Loading
// ==============================================================================
- (void)loadDocumentationData
{
    // Lade die lokale documentation.json (muss im selben Verzeichnis wie index.html liegen)
    var request = [CPURLRequest requestWithURL:"documentation.json"];
    
    [CPURLConnection sendAsynchronousRequest:request queue:[CPOperationQueue mainQueue] completionHandler:function(response, data, error) {
        if (error || !data) {
            CPLog.error("Fehler beim Laden der documentation.json: " + error);
            [self renderHTMLForError:"Could not load documentation.json. Please ensure the file exists in the root directory."];
            return;
        }
        
        try {
            var jsonArray = JSON.parse(data);
            [self buildTreeFromJSON:jsonArray];
        } catch (e) {
            CPLog.error("Fehler beim Parsen der JSON: " + e.message);
            [self renderHTMLForError:"Invalid JSON format."];
        }
    }];
}

- (void)buildTreeFromJSON:(JSObject)jsonArray
{
    [_allRoots removeAllObjects];
    
    for (var i = 0; i < jsonArray.length; i++) {
        var clsData = jsonArray[i];
        var title = clsData.metadata.title || "Unknown Class";
        var clsNode = [[DocNode alloc] initWithTitle:title type:"class" data:clsData];
        
        var topics = clsData.topics || [];
        for (var j = 0; j < topics.length; j++) {
            var topicData = topics[j];
            var topicNode = [[DocNode alloc] initWithTitle:topicData.title type:"topic" data:topicData];
            
            var symbols = topicData.symbols || [];
            for (var k = 0; k < symbols.length; k++) {
                var symData = symbols[k];
                var symNode = [[DocNode alloc] initWithTitle:symData.name type:"symbol" data:symData];
                [[topicNode children] addObject:symNode];
            }
            [[clsNode children] addObject:topicNode];
        }
        [_allRoots addObject:clsNode];
    }
    
    _displayedRoots = [_allRoots copy];
    [outlineView reloadData];
    
    if ([_displayedRoots count] > 0) {
        [outlineView expandItem:_displayedRoots[0]];
    }
}

// ==============================================================================
// Search & Filter
// ==============================================================================
- (void)searchAction:(id)sender
{
    var searchTerm = [[sender stringValue] lowercaseString];
    
    if (!searchTerm || [searchTerm length] === 0) {
        _displayedRoots = [_allRoots copy];
        [outlineView reloadData];
        return;
    }
    
    var filteredRoots = [[CPMutableArray alloc] init];
    
    // Einfache Suche: Iteriere durch den Baum
    for (var i = 0; i < [_allRoots count]; i++) {
        var clsNode = _allRoots[i];
        
        // Wenn die Klasse direkt matched, nimm sie ganz
        if ([[[clsNode title] lowercaseString] hasPrefix:searchTerm] || [[[clsNode title] lowercaseString] rangeOfString:searchTerm].location !== CPNotFound) {
            [filteredRoots addObject:clsNode];
            continue;
        }
        
        var matchedTopics = [[CPMutableArray alloc] init];
        
        for (var j = 0; j < [[clsNode children] count]; j++) {
            var topicNode = [clsNode children][j];
            var matchedSymbols = [[CPMutableArray alloc] init];
            
            for (var k = 0; k < [[topicNode children] count]; k++) {
                var symNode = [topicNode children][k];
                if ([[[symNode title] lowercaseString] rangeOfString:searchTerm].location !== CPNotFound) {
                    [matchedSymbols addObject:symNode];
                }
            }
            
            // Wenn Topic oder ein Symbol matched, füge das Topic (mit gefilterten Symbolen) hinzu
            if ([matchedSymbols count] > 0 || [[[topicNode title] lowercaseString] rangeOfString:searchTerm].location !== CPNotFound) {
                var newTopic = [[DocNode alloc] initWithTitle:[topicNode title] type:[topicNode type] data:[topicNode data]];
                [newTopic setChildren:([matchedSymbols count] > 0 ? matchedSymbols : [topicNode children])];
                [matchedTopics addObject:newTopic];
            }
        }
        
        // Wenn Topics für diese Klasse existieren, füge gefilterte Klasse hinzu
        if ([matchedTopics count] > 0) {
            var newCls = [[DocNode alloc] initWithTitle:[clsNode title] type:[clsNode type] data:[clsNode data]];
            [newCls setChildren:matchedTopics];
            [filteredRoots addObject:newCls];
        }
    }
    
    _displayedRoots = filteredRoots;
    [outlineView reloadData];
    
    // Klappe alles auf, wenn gesucht wird
    [outlineView expandItem:nil expandChildren:YES];
}

// ==============================================================================
// CPOutlineView Data Source & Delegate
// ==============================================================================
- (int)outlineView:(CPOutlineView)anOutlineView numberOfChildrenOfItem:(id)anItem
{
    if (anItem === nil) return [_displayedRoots count];
    return [[anItem children] count];
}

- (BOOL)outlineView:(CPOutlineView)anOutlineView isItemExpandable:(id)anItem
{
    if (anItem === nil) return YES;
    return [[anItem children] count] > 0;
}

- (id)outlineView:(CPOutlineView)anOutlineView child:(int)index ofItem:(id)anItem
{
    if (anItem === nil) return _displayedRoots[index];
    return [[anItem children] objectAtIndex:index];
}

- (id)outlineView:(CPOutlineView)anOutlineView objectValueForTableColumn:(CPTableColumn)tableColumn byItem:(id)anItem
{
    return [anItem title];
}

- (void)outlineViewSelectionDidChange:(CPNotification)notification
{
    var selectedRow = [outlineView selectedRow];
    if (selectedRow === -1) {
        [docWebView loadHTMLString:""];
        return;
    }
    
    var selectedItem = [outlineView itemAtRow:selectedRow];
    [self renderHTMLForNode:selectedItem];
}

// ==============================================================================
// HTML Rendering für die Dokumentation
// ==============================================================================
- (void)renderHTMLForError:(CPString)errorMessage
{
    var html = "<div style='padding: 20px; font-family: sans-serif; color: red;'>" + errorMessage + "</div>";
    [docWebView loadHTMLString:html];
}

- (void)renderHTMLForNode:(DocNode)node
{
    var type = [node type];
    var data = [node data];
    
    // Basis-Styling à la Apple DocC
    var html = @"<html><head><style>" +
               @"body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 30px; color: #1d1d1f; line-height: 1.5; }" +
               @"h1 { font-size: 32px; margin-bottom: 5px; }" +
               @"h2 { font-size: 24px; border-bottom: 1px solid #d2d2d7; padding-bottom: 8px; margin-top: 30px; }" +
               @"pre { background: #f5f5f7; padding: 15px; border-radius: 8px; overflow-x: auto; font-family: 'SF Mono', Consolas, monospace; font-size: 14px; border: 1px solid #d2d2d7; }" +
               @".badge { display: inline-block; background: #0071e3; color: white; padding: 3px 8px; border-radius: 12px; font-size: 12px; font-weight: bold; margin-bottom: 10px; }" +
               @".meta { color: #86868b; font-size: 14px; margin-bottom: 20px; }" +
               @"p { font-size: 16px; }" +
               @"</style></head><body>";
               
    if (type === "class") {
        html += "<span class='badge'>" + (data.metadata.role || "Class").toUpperCase() + "</span>";
        html += "<h1>" + [node title] + "</h1>";
        html += "<div class='meta'>Inherits from: " + (data.metadata.superclass || "CPObject") + " &nbsp;|&nbsp; Framework: " + data.metadata.framework + "</div>";
        
        if (data.primaryContent && data.primaryContent.declaration) {
            html += "<h2>Declaration</h2><pre>" + data.primaryContent.declaration + "</pre>";
        }
        
        if (data.primaryContent && data.primaryContent.abstract) {
            html += "<h2>Overview</h2><p>" + data.primaryContent.abstract + "</p>";
        }
        
        if (data.primaryContent && data.primaryContent.discussion) {
            html += "<p>" + data.primaryContent.discussion + "</p>";
        }
    } 
    else if (type === "topic") {
        html += "<h1>" + [node title] + "</h1>";
        if (data.abstract) {
            html += "<p>" + data.abstract + "</p>";
        }
        
        // Liste die Symbole im Topic auf
        html += "<h2>Symbols</h2><ul>";
        var syms = data.symbols || [];
        for (var i = 0; i < syms.length; i++) {
            html += "<li><strong>" + syms[i].name + "</strong>";
            if (syms[i].abstract) html += " - " + syms[i].abstract;
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
            html += "<h2>Overview</h2><p>" + data.abstract + "</p>";
        }
        
        // Parameter auflisten falls vorhanden
        if (data.parameters && data.parameters.length > 0) {
            html += "<h2>Parameters</h2><ul>";
            for (var i = 0; i < data.parameters.length; i++) {
                var p = data.parameters[i];
                html += "<li><code>" + p.name + "</code> (" + p.type + ")</li>";
            }
            html += "</ul>";
        }
        
        // Return type anzeigen
        if (data.returnType && data.returnType !== "void") {
            html += "<h2>Return Value</h2><p>Type: <code>" + data.returnType + "</code></p>";
        }
        
        // Values auflisten (bei Enums/Typedefs)
        if (data.values && data.values.length > 0) {
            html += "<h2>Values</h2><ul>";
            for (var i = 0; i < data.values.length; i++) {
                html += "<li><code>" + data.values[i].name + "</code> = " + data.values[i].value + "</li>";
            }
            html += "</ul>";
        }
    }

    html += "</body></html>";
    [docWebView loadHTMLString:html];
}

@end