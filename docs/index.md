---
title: Zangle's landing page
...

# Abstract

Zangle is a tool for literate programming compatible with pandoc. This example
displays the use of zangle to structure it's own landing page with interactive
content.

# Index

```{.html file="index.html"}
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Zangle - a literate document tool</title>
    {{resources}}
  </head>
  <body>

    <div class="section intro">
      {{navbar}}
    </div>

    <div class="section main">
      {{main-content}}
    </div>

    <div class="section footer">
      {{footer}}
    </div>

  </body>
</html>
```

# Navbar

```{.html #navbar}
<span class="logo">
  {{zangle-logo}}
</span>
```

```{.css #navbar-css}
.nav-logo {}


.logo {
  display: flex;
  justify-content: center;
}

.logo > svg {
  width: 5em;
  height: 5em;
  fill: {{logo-colour}};
}
```

# Main

```{.html #main-content}
<div class="container">
  <div class="row">
    <span class="nine columns">
      <p>{{short-description-of-zangle}}</p>
    </span>
    <span class="three columns">
      insert image here
    </span>
  </div>

  <div class="row">
    <span class="three columns">
      insert image here
    </span>
    <span class="nine columns">
      <p>{{short-description-of-zangle}}</p>
    </span>
  </div>
</div>

```

```{.txt #short-description-of-zangle}
<span class="zangle">Zangle</span> is a literate programming tool compatible
with pandoc markdown in the form of a library with a command-line frontend.

```

```{.css #main-block}
.zangle { color: {{logo-colour}}; }
.main {
  display: block;
  height: 100%;
  width: 100%;
  padding-top: 10em;
}
```

## Example code block


```{.html #main-content}
<div class="code-block">
  <div class="container">
    <pre>
      <code class="code">
{{example-code-block}}
      </code>
    </pre>
  </div>
</div>

```


```{.zig #example-code-block}

const std = @import("std");
const zangle = @import("zangle");

pub fn main() !void {
    const config = &lt;&lt;parse-command-line-arguments&gt;&gt;;
    for (config.files) |filename| {
        &lt;&lt;read-all-files-into-a-joint-buffer&gt;&gt;;
    }

    var tree = try parse(gpa, source.items, .{});
    defer tree.deinit();

    &lt;&lt;do-awesome-stuff-with-the-document&gt;&gt;
}
```

```{.css #main-block}
.code-block {
  margin-bottom: 2em;
  margin-top: 2em;
  padding: 0em;
  width: 100vw;
  border: none;
  color: {{code-normal-colour}};
  background-color: {{code-block-colour}};
}

.code-block > .container > pre {
  margin: 0em;
}

.code {
  margin: 0em;
  padding: 0em;
  border-radius: 0;
  border: none;
  color: {{code-normal-colour}};
  background-color: {{code-block-colour}};

}
```

## Filters

```{.html #main-content}
<h3 class="filters-header">Filters (incomplete)</h3>
<div class="container">
  <p>{{short-filter-description}}</p>
</div>

<div class="code-block">
  <div class="container">
    <div class="seven columns">
      <pre>
        <code class="code">
{{filter-zangle-code-block:escape html}}
        </code>
      </pre>
    </div>

    <div class="five columns">
      <pre>
        <code class="code">
{{filter-zig-code-block:escape html}}
        </code>
      </pre>
    </div>
  </div>
</div>
```

```{.txt #short-filter-description}
<span class="zangle">Zangle</span> supports both inline and external filters on
placeholders which enable running additional tools over the tangled code block
before it's written to the document.
```

~~~{.txt delimiter="none" #filter-zangle-code-block}

```{.html delimiter="brace" #html-escape-example}
&lt;html&gt;
  &lt;head&gt;
    &lt;meta charset="utf-8"/&gt;
    &lt;title&gt;Zangle - Iterate over filenames&lt;/title&gt;
  &lt;/head&gt;
  &lt;body&gt;
    &lt;pre&gt;
      &lt;code&gt;
        {{example-code-block:escape html}}
      &lt;/code&gt;
    &lt;/pre&gt;
  &lt;/body&gt;
&lt;/html&gt;
```

Serve the code sample!

```{.zig #static-site-example}
text = &lt;&lt;html-escape-example:escape python-multi-string&gt;&gt;

@app.route("/", accept=["GET"])
def index():
    return text
```
~~~

~~~{.txt delimiter="none" #filter-zig-code-block}

```{.zig #example-code-block}
&lt;&lt;imports&gt;&gt;

pub fn main() !void {
    const text = try cwd().readFileAlloc(
        gpa,
        "filters.md",
    );
    defer gpa.free(text);

    var tree = try parse(gpa, text, .{});
    defer tree.deinit();

    try stdout.writeAll("&lt;ul&gt;");

    var it = tree.query(.filename);
    while (it.next()) |filename| {
        try stdout.print(
            \\&lt;li&gt;{s}&lt;/li&gt;
        , .{filename});
    }

    try stdout.writeAll("&lt;/ul&gt;");
}
```
~~~

```{.css #main-block}
.filters-header {
  color: {{filters-colour}};
  text-align: center;
}
```

## Usable from C and the web

```{.html #main-content}
<h3 class="c-header">Usable from C and the web (incomplete)</h3>
<div class="container">
  <p>{{c-description}}</p>
</div>
```

```{.html #c-description}
<span class="zangle">Zangle</span> is usable as a C library and WASM module.
```

```{.css #main-block}
.c-header {
  color: {{c-colour}};
  text-align: center;
}
```

## Try it!

```{.html #main-content}
<h3 class="tryit-header">Try it! (incomplete)</h3>
<div class="container">
  <span class="nine columns">
    <textarea id="tryit-block" class="tryit-block"></textarea>
  </span>
  <span class="three columns">
    results here
  </span>
</div>
<div class="container">
  {{tryit-description}}
</div>
```

```{.txt #tryit-description}
Try it
```


```{.css #main-block}
.tryit-header {
  color: {{tryit-colour}};
  text-align: center;
}
.tryit-block {
  border: none;
  width: 100%;
  height: 30em;
  background-color: {{light-yellow}};
}
```

# Footer


```{.html #footer}
<div class="container">
  <div class="row">
    <span class="three columns">
      {{first-row-links}}
    </span>
    <span class="three columns">
      <div>a</div>
      <div>a</div>
      <div>a</div>
    </span>
  </div>
</div>
```

```{.html #first-row-links}
<ul>
  <li>Github</li>
  <li>a</li>
  <li>b</li>
  <li>c</li>
</ul>
```

# Style

```{.css file="assets/css/custom.css"}
.section {
  width: 100%;
}

/* NAVBAR */
{{navbar-css}}

.intro {
  top: 0em;
  width: 100%;
  position: absolute;
  background-color: {{intro-colour}};
}

{{main-block}}

body {
  background-color: {{main-colour}};
}

.footer {
  padding-top: 3em;
  height: 20em;
  width: 100%;
  background-color: {{footer-colour}};
}

p { font-size: 1.5em; }

.center.horizontal {
  display: block;
  margin-left: auto;
  margin-right: auto;
}
```

# Colours

| colour                                           |
| --                                               |
| `#000000`{.css #black}                           |
| `#d85229`{.css #bright-orange #highlight}        |
| `#ecf0e7`{.css #lighter-green #main-colour}      |
| `#ccd1c8`{.css #light-green #footer-colour}      |
| `#f6f5ee`{.css #light-yellow #intro-colour}      |
| `#ffffff`{.css #white}                           |
| `#555555`{.css #grey #link-colour}               |
| `#898f93`{.css #light-grey}                      |
| `#999999`{.css #lighter-grey}                    |
| `#cfd2cb`{.css #lightest-grey}                   |
| `#00a6d4`{.css #cyan}                            |
| `#007bb6`{.css #blue #tryit-colour}              |
| `#2bb37c`{.css #green #filters-colour}           |
| `#5168a4`{.css #purple #logo-colour}             |
| `#664270`{.css #magenta #c-colour}               |
| `#1d2021`{.css #blue-grey #code-block-colour}    |
| `#eeeeee`{.css #paper-white #code-normal-colour} |

: Colours used on the site

# Resources

```{.html #resources}
<link rel="stylesheet" href="assets/css/normalize.css" />
<link rel="stylesheet" href="assets/css/skeleton.css" />
<link rel="stylesheet" href="assets/css/custom.css" />
```

```{.svg file="assets/svg/logo.svg" #zangle-logo}
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.0//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd">
<svg xmlns="http://www.w3.org/2000/svg"  xmlns:xlink="http://www.w3.org/1999/xlink" width='86.711mm' height='71.569mm' viewBox="0 0 86.711 71.569">

<title>Exported SVG</title>

<style><![CDATA[
polygon {
shape-rendering:crispEdges;
stroke-width:0.086711;
}
.s1 {
  stroke:#000000;
  stroke-width:0.086806;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s2 {
  stroke:#19b219;
  stroke-width:0.086806;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s3 {
  stroke:#7f4c00;
  stroke-width:0.086806;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s4 {
  stroke:#00cc00;
  stroke-width:0.086806;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s5 {
  stroke:#000000;
  stroke-width:0.057870;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s6 {
  stroke:#ff19ff;
  stroke-width:0.057870;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s7 {
  stroke:#ff0000;
  stroke-width:0.086806;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s8 {
  stroke:#ffff00;
  stroke-width:0.086806;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.s9 {
  stroke:#001919;
  stroke-width:0.057870;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.sa {
  stroke:#006666;
  stroke-width:0.057870;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.sb {
  stroke:#00ffff;
  stroke-width:0.173611;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.sc {
  stroke:#ff0000;
  stroke-width:0.462963;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.sd {
  stroke:#191919;
  stroke-width:0.057870;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
.se {
  stroke:#000000;
  stroke-width:0.057870;
  stroke-linecap:round;
  stroke-linejoin:round;
  stroke-dasharray:0.868,0.868;
fill:none;
}
.sf {
  stroke:#000000;
  stroke-width:0.173611;
  stroke-linecap:round;
  stroke-linejoin:round;
  fill:none;
}
]]></style>
<path d='M78.071 61.569 L58.142,61.569 A31.926,31.926 0 0,0 48.477,38.234 L81.711,5.000 L74.640,5.000 L13.071,66.569 L73.071,66.569 L78.071,61.569 M46.355 40.355 A31.926,31.926 0 0,1 55.142,61.569 L25.142,61.569 L46.355,40.355 ' class='s0' />
<path d='M61.162 46.744 Q61.660,45.959 61.627,44.606 Q61.593,43.246 61.060,42.490 Q60.526,41.735 59.618,41.757 Q58.709,41.779 58.213,42.560 Q57.717,43.341 57.750,44.701 Q57.783,46.054 58.317,46.814 Q58.851,47.573 59.758,47.550 Q60.664,47.528 61.162,46.744 M59.023 44.455 Q59.004,43.245 59.129,42.764 Q59.276,42.193 59.628,42.184 Q59.980,42.176 60.152,42.739 Q60.300,43.213 60.340,44.422 L59.023,44.455 M60.351 44.857 Q60.371,46.110 60.249,46.583 Q60.112,47.118 59.747,47.127 Q59.383,47.136 59.219,46.608 Q59.078,46.141 59.033,44.889 L60.351,44.857 ' class='s0' />
<path d='M12.071 66.569 L73.640,5.000 L13.640,5.000 L8.640,10.000 L61.569,10.000 L5.000,66.569 L12.071,66.569 ' class='s0' />
</svg>
```
