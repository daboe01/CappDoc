# CappuDoc

An interactive, desktop-class documentation browser designed for the Cappuccino (Objective-J) framework. It includes a Perl-based static analysis parser to extract Doxygen-compatible comment blocks, method signatures, variables, and deprecations, paired with a web-based Objective-J viewer application.

## Features

* **Visual Type Indicators**: Color-coded circles in the class tree align with document badges for easy identification of node types:
  * 🔵 **Class**
  * 🟢 **Topic**
  * 🟠 **Class Method**
  * 🔴 **Instance Method**
  * 🟡 **Global Variable**
  * 🟤 **Typedef**
* **Doxygen Support**: Parses standard tag directives (such as `@param`, `@return`, `@throws`, `@delegate`, and `@par`) and strips out internal categorization blocks automatically.
* **Inline HTML Rendering**: Whitelist-based sanitization preserves standard layout tags (like `<p>`, `<strong>`, `<pre>`, `<ul>`, `<ol>`, `<li>`, `<code>`, and `<a>`) so code examples and lists format natively.
* **Deprecation Warnings**: Automatically highlights deprecated classes, methods, or enum constants with distinct strikethrough styling and alert banners, mapping messages like `@deprecated in favor of...` directly into the UI.
* **Logical Sorting**: Subclasses are sorted alphabetically and kept grouped at the bottom of the tree hierarchy—below topics and class/instance methods—to facilitate navigation.
* **Search Tools**: Fast full-text search across documentation fields with a toggle to restrict lookups to "Titles only".

---

## Getting Started

Using CappDoc consists of two steps: running the static code parser on your framework source files to generate a unified JSON database, and serving the viewer application.

### 1. Generating the Documentation Database

Run the provided Perl script, passing the paths to your Objective-J source folders. Redirect the stdout stream to a file named `documentation.json` in your CappDoc workspace folder.

```bash
perl /Users/daboe01/src/CappDoc/generate_docs.pl /Users/daboe01/src/cappuccino/AppKit > documentation.json
```

*Note: You can pass multiple directory paths separated by spaces if you want to index both AppKit and Foundation concurrently.*

### 2. Serving the Web Application

Because the browser client fetches the parsed database dynamically via XMLHttpRequest, the application must be served through a web server to satisfy security constraints.

Start the Python web server from your workspace directory:

```bash
python3 -m http.server
```

By default, the server listens on port `8000`. Open your browser of choice and navigate to:

```text
http://localhost:8000
```

---

## Repository Structure

* **`generate_docs.pl`**: The Perl parser script. It recursively scans folders, filters internal files, processes documentation blocks, categorizes methods by scope, and writes the structured metadata to standard output.
* **`AppController.j`**: The main Objective-J application controller. It manages the dual-pane UI (`CPOutlineView` and `CPWebView`), implements search/navigation mechanics, sorts the class tree hierarchy, and compiles the formatted HTML detail views.
* **`main.j` / `Resources/`**: Standard bootstrap files and assets for the Cappuccino runtime.
