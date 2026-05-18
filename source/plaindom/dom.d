// FIXME: xml namespace support???
// FIXME: https://developer.mozilla.org/en-US/docs/Web/API/Element/insertAdjacentHTML
// FIXME: parentElement is parentNode that skips DocumentFragment etc but will be hard to work in with my compatibility...

/++
	This is an html DOM implementation, started with cloning
	what the browser offers in Javascript, but going well beyond
	it in convenience.

	If you can do it in Javascript, you can probably do it with
	this module, and much more.

	---
	import plaindom;

	void main() {
		auto document = new Document("<html><p>paragraph</p></html>");
		writeln(document.querySelector("p"));
		document.root.innerHTML = "<p>hey</p>";
		writeln(document);
	}
	---

	BTW: this file optionally depends on `plaindom.characterencodings`, to
	help it correctly read files from the internet. You should be able to
	get characterencodings.d from the same place you got this file.

	If you want it to stand alone, just always use the `Document.parseUtf8`
	function or the constructor that takes a string.

	Symbol_groups:

	core_functionality =

	These members provide core functionality. The members on these classes
	will provide most your direct interaction.

	bonus_functionality =

	These provide additional functionality for special use cases.

	implementations =

	These provide implementations of other functionality.
+/
module plaindom.dom;

import plaindom.characterencodings;
import plaindom.entities;

import std.algorithm.searching;
import std.algorithm.sorting;
import std.algorithm.comparison;
import std.algorithm.iteration;
import std.array;
import std.conv;
import std.exception;
import std.range;
import std.stdio;
import std.string;
import std.uri;
import std.uni;
import std.utf;

// FIXME: support the css standard namespace thing in the selectors too


// FIXME: something like <ol>spam <ol> with no closing </ol> should read the second tag as the closer in garbage mode
// FIXME: failing to close a paragraph sometimes messes things up too

// FIXME: it would be kinda cool to have some support for internal DTDs
// and maybe XPath as well, to some extent
/*
	we could do
	meh this sux

	auto xpath = XPath(element);

	     // get the first p
	xpath.p[0].a["href"]
*/


/++
	The main document interface, including a html or xml parser.

	There's three main ways to create a Document:

	If you want to parse something and inspect the tags, you can use the [this|constructor]:
	---
		// create and parse some HTML in one call
		auto document = new Document("<html></html>");

		// or some XML
		auto document = new Document("<xml></xml>", true, true); // strict mode enabled

		// or better yet:
		auto document = new XmlDocument("<xml></xml>"); // specialized subclass
	---

	If you want to download something and parse it in one call, the [fromUrl] static function can help:
	---
		auto document = Document.fromUrl("http://dlang.org/");
	---

	And, if you need to inspect things like `<%= foo %>` tags and comments, you can add them to the dom like this, with the [enableAddingSpecialTagsToDom]
	and [parseUtf8] or [parseGarbage] functions:
	---
		auto document = new Document();
		document.enableAddingSpecialTagsToDom();
		document.parseUtf8("<example></example>", true, true); // changes the trues to false to switch from xml to html mode
	---

	You can also modify things like [selfClosedElements] and [rawSourceElements] before calling the `parse` family of functions to do further advanced tasks.

	However you parse it, it will put a few things into special variables.

	[root] contains the root document.
	[prolog] contains the instructions before the root (like `<!DOCTYPE html>`). To keep the original things, you will need to [enableAddingSpecialTagsToDom] first, otherwise the library will return generic strings in there. [piecesBeforeRoot] will have other parsed instructions, if [enableAddingSpecialTagsToDom] is called.
	[piecesAfterRoot] will contain any xml-looking data after the root tag is closed.

	Most often though, you will not need to look at any of that data, since `Document` itself has methods like [querySelector], [appendChild], and more which will forward to the root [Element] for you.
+/
/// Group: core_functionality
class Document : DomParent {
	inout(Document) asDocument() inout @safe pure { return this; }
	inout(Element) asElement() inout @safe pure { return null; }

	void processNodeWhileParsing(Element parent, Element child) @safe pure {
		parent.appendChild(child);
	}

	/++
		Creates a document with the given source data. If you want HTML behavior, use `caseSensitive` and `struct` set to `false`. For XML mode, set them to `true`.

		Please note that anything after the root element will be found in [piecesAfterRoot]. Comments, processing instructions, and other special tags will be stripped out b default. You can customize this by using the zero-argument constructor and setting callbacks on the [parseSawComment], [parseSawBangInstruction], [parseSawAspCode], [parseSawPhpCode], and [parseSawQuestionInstruction] members, then calling one of the [parseUtf8], [parseGarbage], or [parse] functions. Calling the convenience method, [enableAddingSpecialTagsToDom], will enable all those things at once.

		See_Also:
			[parseGarbage]
			[parseUtf8]
			[parseUrl]
	+/
	this(string data, bool caseSensitive = false, bool strict = false) @safe pure {
		parseUtf8(data, caseSensitive, strict);
	}

	/**
		Creates an empty document. It has *nothing* in it at all, ready.
	*/
	this() @safe pure {

	}

	/++
		This is just something I'm toying with. Right now, you use opIndex to put in css selectors.
		It returns a struct that forwards calls to all elements it holds, and returns itself so you
		can chain it.

		Example: document["p"].innerText("hello").addClass("modified");

		Equivalent to: foreach(e; document.getElementsBySelector("p")) { e.innerText("hello"); e.addClas("modified"); }

		Note: always use function calls (not property syntax) and don't use toString in there for best results.

		You can also do things like: document["p"]["b"] though tbh I'm not sure why since the selector string can do all that anyway. Maybe
		you could put in some kind of custom filter function tho.
	+/
	ElementCollection opIndex(string selector) @safe pure {
		auto e = ElementCollection(this.root);
		return e[selector];
	}

	string _contentType = "text/html; charset=utf-8";

	/// If you're using this for some other kind of XML, you can
	/// set the content type here.
	///
	/// Note: this has no impact on the function of this class.
	/// It is only used if the document is sent via a protocol like HTTP.
	///
	/// This may be called by parse() if it recognizes the data. Otherwise,
	/// if you don't set it, it assumes text/html; charset=utf-8.
	@property string contentType(string mimeType) @safe pure {
		_contentType = mimeType;
		return _contentType;
	}

	/// implementing the FileResource interface, useful for sending via
	/// http automatically.
	@property string filename() const @safe pure { return null; }

	/// implementing the FileResource interface, useful for sending via
	/// http automatically.
	@property string contentType() const @safe pure {
		return _contentType;
	}

	/// implementing the FileResource interface; it calls toString.
	immutable(ubyte)[] getData() const @safe pure {
		return cast(immutable(ubyte)[]) this.toString();
	}


	/*
	/// Concatenates any consecutive text nodes
	void normalize() {

	}
	*/

	/// This will set delegates for parseSaw* (note: this overwrites anything else you set, and you setting subsequently will overwrite this) that add those things to the dom tree when it sees them.
	/// Call this before calling parse().

	/++
		Adds objects to the dom representing things normally stripped out during the default parse, like comments, `<!instructions>`, `<% code%>`, and `<? code?>` all at once.

		Note this will also preserve the prolog and doctype from the original file, if there was one.

		See_Also:
			[parseSawComment]
			[parseSawAspCode]
			[parseSawPhpCode]
			[parseSawQuestionInstruction]
			[parseSawBangInstruction]
	+/
	void enableAddingSpecialTagsToDom() @safe pure {
		parseSawComment = (string) => true;
		parseSawAspCode = (string) => true;
		parseSawPhpCode = (string) => true;
		parseSawQuestionInstruction = (string) => true;
		parseSawBangInstruction = (string) => true;
	}

	/// If the parser sees a html comment, it will call this callback
	/// <!-- comment --> will call parseSawComment(" comment ")
	/// Return true if you want the node appended to the document. It will be in a [HtmlComment] object.
	bool delegate(string) @safe pure parseSawComment;

	/// If the parser sees <% asp code... %>, it will call this callback.
	/// It will be passed "% asp code... %" or "%= asp code .. %"
	/// Return true if you want the node appended to the document. It will be in an [AspCode] object.
	bool delegate(string) @safe pure parseSawAspCode;

	/// If the parser sees <?php php code... ?>, it will call this callback.
	/// It will be passed "?php php code... ?" or "?= asp code .. ?"
	/// Note: dom.d cannot identify  the other php <? code ?> short format.
	/// Return true if you want the node appended to the document. It will be in a [PhpCode] object.
	bool delegate(string) @safe pure parseSawPhpCode;

	/// if it sees a <?xxx> that is not php or asp
	/// it calls this function with the contents.
	/// <?SOMETHING foo> calls parseSawQuestionInstruction("?SOMETHING foo")
	/// Unlike the php/asp ones, this ends on the first > it sees, without requiring ?>.
	/// Return true if you want the node appended to the document. It will be in a [QuestionInstruction] object.
	bool delegate(string) @safe pure parseSawQuestionInstruction;

	/// if it sees a <! that is not CDATA or comment (CDATA is handled automatically and comments call parseSawComment),
	/// it calls this function with the contents.
	/// <!SOMETHING foo> calls parseSawBangInstruction("SOMETHING foo")
	/// Return true if you want the node appended to the document. It will be in a [BangInstruction] object.
	bool delegate(string) @safe pure parseSawBangInstruction;

	/// Given the kind of garbage you find on the Internet, try to make sense of it.
	/// Equivalent to document.parse(data, false, false, null);
	/// (Case-insensitive, non-strict, determine character encoding from the data.)

	/// NOTE: this makes no attempt at added security, but it will try to recover from anything instead of throwing.
	void parseGarbage(string data) @safe pure {
		parse(data, false, false, null);
	}

	/// Parses well-formed UTF-8, case-sensitive, XML or XHTML
	/// Will throw exceptions on things like unclosed tags.
	void parseStrict(string data, bool pureXmlMode = false) @safe pure {
		parseStream(toUtf8Stream(data), true, true, pureXmlMode);
	}

	/// Parses well-formed UTF-8 in loose mode (by default). Tries to correct
	/// tag soup, but does NOT try to correct bad character encodings.
	///
	/// They will still throw an exception.
	void parseUtf8(string data, bool caseSensitive = false, bool strict = false) @safe pure {
		parseStream(toUtf8Stream(data), caseSensitive, strict);
	}

	Utf8Stream handleDataEncoding(in string rawdata, string dataEncoding, bool strict) @safe pure {
		// gotta determine the data encoding. If you know it, pass it in above to skip all this.
		if(dataEncoding is null) {
			dataEncoding = tryToDetermineEncoding(cast(immutable(ubyte[])) rawdata);
			// it can't tell... probably a random 8 bit encoding. Let's check the document itself.
			// Now, XML and HTML can both list encoding in the document, but we can't really parse
			// it here without changing a lot of code until we know the encoding. So I'm going to
			// do some hackish string checking.
			if(dataEncoding is null) {
				auto dataAsBytes = cast(immutable(ubyte)[]) rawdata;
				// first, look for an XML prolog
				auto idx = indexOfBytes(dataAsBytes, cast(immutable ubyte[]) "encoding=\"");
				if(idx != -1) {
					idx += "encoding=\"".length;
					// we're probably past the prolog if it's this far in; we might be looking at
					// content. Forget about it.
					if(idx > 100)
						idx = -1;
				}
				// if that fails, we're looking for Content-Type http-equiv or a meta charset (see html5)..
				if(idx == -1) {
					idx = indexOfBytes(dataAsBytes, cast(immutable ubyte[]) "charset=");
					if(idx != -1) {
						idx += "charset=".length;
						if(dataAsBytes[idx] == '"')
							idx++;
					}
				}

				// found something in either branch...
				if(idx != -1) {
					// read till a quote or about 12 chars, whichever comes first...
					auto end = idx;
					while(end < dataAsBytes.length && dataAsBytes[end] != '"' && end - idx < 12)
						end++;

					dataEncoding = cast(string) dataAsBytes[idx .. end];
				}
				// otherwise, we just don't know.
			}
		}

		if(dataEncoding is null) {
			if(strict)
				throw new MarkupException("I couldn't figure out the encoding of this document.");
			else
			// if we really don't know by here, it means we already tried UTF-8,
			// looked for utf 16 and 32 byte order marks, and looked for xml or meta
			// tags... let's assume it's Windows-1252, since that's probably the most
			// common aside from utf that wouldn't be labeled.

			dataEncoding = "Windows 1252";
		}

		// and now, go ahead and convert it.

		string data;

		if(!strict) {
			// if we're in non-strict mode, we need to check
			// the document for mislabeling too; sometimes
			// web documents will say they are utf-8, but aren't
			// actually properly encoded. If it fails to validate,
			// we'll assume it's actually Windows encoding - the most
			// likely candidate for mislabeled garbage.
			dataEncoding = dataEncoding.toLower();
			dataEncoding = dataEncoding.replace(" ", "");
			dataEncoding = dataEncoding.replace("-", "");
			dataEncoding = dataEncoding.replace("_", "");
			if(dataEncoding == "utf8") {
				try {
					validate(rawdata);
				} catch(UTFException e) {
					dataEncoding = "Windows 1252";
				}
			}
		}

		if(dataEncoding != "UTF-8") {
			if(strict)
				data = convertToUtf8(cast(immutable(ubyte)[]) rawdata, dataEncoding);
			else {
				try {
					data = convertToUtf8(cast(immutable(ubyte)[]) rawdata, dataEncoding);
				} catch(Exception e) {
					data = convertToUtf8(cast(immutable(ubyte)[]) rawdata, "Windows 1252");
				}
			}
		} else
			data = rawdata;

		return toUtf8Stream(data);
	}

	private
	Utf8Stream toUtf8Stream(in string rawdata) @safe pure {
		string data = rawdata;
		static if(is(Utf8Stream == string))
			return data;
		else
			return new Utf8Stream(data);
	}

	/++
		List of elements that can be assumed to be self-closed
		in this document. The default for a Document are a hard-coded
		list of ones appropriate for HTML. For [XmlDocument], it defaults
		to empty. You can modify this after construction but before parsing.

		History:
			Added February 8, 2021 (included in dub release 9.2)

			Changed from `string[]` to `immutable(string)[]` on
			February 4, 2024 (dub v11.5) to plug a hole discovered
			by the OpenD compiler's diagnostics.
	+/
	immutable(string)[] selfClosedElements = htmlSelfClosedElements;

	/++
		List of elements that contain raw CDATA content for this
		document, e.g. `<script>` and `<style>` for HTML. The parser
		will read until the closing string and put everything else
		in a [RawSource] object for future processing, not trying to
		do any further child nodes or attributes, etc.

		History:
			Added February 4, 2024 (dub v11.5)

	+/
	immutable(string)[] rawSourceElements = htmlRawSourceElements;

	/++
		List of elements that are considered inline for pretty printing.
		The default for a Document are hard-coded to something appropriate
		for HTML. For [XmlDocument], it defaults to empty. You can modify
		this after construction but before parsing.

		History:
			Added June 21, 2021 (included in dub release 10.1)

			Changed from `string[]` to `immutable(string)[]` on
			February 4, 2024 (dub v11.5) to plug a hole discovered
			by the OpenD compiler's diagnostics.
	+/
	immutable(string)[] inlineElements = htmlInlineElements;

	/**
		Take XMLish data and try to make the DOM tree out of it.

		The goal isn't to be perfect, but to just be good enough to
		approximate Javascript's behavior.

		If strict, it throws on something that doesn't make sense.
		(Examples: mismatched tags. It doesn't validate!)
		If not strict, it tries to recover anyway, and only throws
		when something is REALLY unworkable.

		If strict is false, it uses a magic list of tags that needn't
		be closed. If you are writing a document specifically for this,
		try to avoid such - use self closed tags at least. Easier to parse.

		The dataEncoding argument can be used to pass a specific
		charset encoding for automatic conversion. If null (which is NOT
		the default!), it tries to determine from the data itself,
		using the xml prolog or meta tags, and assumes UTF-8 if unsure.

		If this assumption is wrong, it can throw on non-ascii
		characters!


		Note that it previously assumed the data was encoded as UTF-8, which
		is why the dataEncoding argument defaults to that.

		So it shouldn't break backward compatibility.

		But, if you want the best behavior on wild data - figuring it out from the document
		instead of assuming - you'll probably want to change that argument to null.

		If you are sure the encoding is good, try parseUtf8 or parseStrict to avoid the
		dependency. If it is data from the Internet though, a random website, the encoding
		is often a lie. This function, if dataEncoding == null, can correct for that, or
		you can try parseGarbage. In those cases, plaindom.characterencodings is required to
		compile.
	*/
	void parse(in string rawdata, bool caseSensitive = false, bool strict = false, string dataEncoding = "UTF-8") @safe pure {
		auto data = handleDataEncoding(rawdata, dataEncoding, strict);
		parseStream(data, caseSensitive, strict);
	}

	private string[] recentAutoClosedTags;
	// note: this work best in strict mode, unless data is just a simple string wrapper
	void parseStream(Utf8Stream data, bool caseSensitive = false, bool strict = false, bool pureXmlMode = false) @safe pure {
		// FIXME: this parser could be faster; it's in the top ten biggest tree times according to the profiler
		// of my big app.

		assert(data !is null);

		// go through character by character.
		// if you see a <, consider it a tag.
		// name goes until the first non tagname character
		// then see if it self closes or has an attribute

		// if not in a tag, anything not a tag is a big text
		// node child. It ends as soon as it sees a <

		// Whitespace in text or attributes is preserved, but not between attributes

		// &amp; and friends are converted when I know them, left the same otherwise


		// this it should already be done correctly.. so I'm leaving it off to net a ~10% speed boost on my typical test file (really)
		//validate(data); // it *must* be UTF-8 for this to work correctly

		sizediff_t pos = 0;

		clear();

		loose = !caseSensitive;

		bool sawImproperNesting = false;
		bool paragraphHackfixRequired = false;

		int getLineNumber(sizediff_t p) {
			int line = 1;
			foreach(c; data[0..p])
				if(c == '\n')
					line++;
			return line;
		}

		void parseError(string message) {
			throw new MarkupException(format("char %d (line %d): %s", pos, getLineNumber(pos), message));
		}

		bool eatWhitespace() @safe pure {
			bool ateAny = false;
			while(pos < data.length && data[pos].isSimpleWhite) {
				pos++;
				ateAny = true;
			}
			return ateAny;
		}

		string readTagName() {
			// remember to include : for namespaces
			// basically just keep going until >, /, or whitespace
			auto start = pos;
			while(data[pos] != '>' && data[pos] != '/' && !data[pos].isSimpleWhite)
			{
				pos++;
				if(pos == data.length) {
					if(strict)
						throw new Exception("tag name incomplete when file ended");
					else
						break;
				}
			}

			if(!caseSensitive)
				return toLower(data[start..pos]);
			else
				return data[start..pos];
		}

		string readAttributeName() @safe pure {
			// remember to include : for namespaces
			// basically just keep going until >, /, or whitespace
			auto start = pos;
			while(data[pos] != '>' && data[pos] != '/'  && data[pos] != '=' && !data[pos].isSimpleWhite)
			{
				if(data[pos] == '<') {
					if(strict)
						throw new MarkupException("The character < can never appear in an attribute name. Line " ~ to!string(getLineNumber(pos)));
					else
						break; // e.g. <a href="something" <img src="poo" /></a>. The > should have been after the href, but some shitty files don't do that right and the browser handles it, so we will too, by pretending the > was indeed there
				}
				pos++;
				if(pos == data.length) {
					if(strict)
						throw new Exception("unterminated attribute name");
					else
						break;
				}
			}

			if(!caseSensitive)
				return toLower(data[start..pos]);
			else
				return data[start..pos];
		}

		string readAttributeValue() @safe pure {
			if(pos >= data.length) {
				if(strict)
					throw new Exception("no attribute value before end of file");
				else
					return null;
			}
			switch(data[pos]) {
				case '\'':
				case '"':
					auto started = pos;
					char end = data[pos];
					pos++;
					auto start = pos;
					while(pos < data.length && data[pos] != end)
						pos++;
					if(strict && pos == data.length)
						throw new MarkupException("Unclosed attribute value, started on char " ~ to!string(started));
					string v = htmlEntitiesDecode(data[start..pos], strict);
					pos++; // skip over the end
				return v;
				default:
					if(strict)
						parseError("Attributes must be quoted");
					// read until whitespace or terminator (/> or >)
					auto start = pos;
					while(
						pos < data.length &&
						data[pos] != '>' &&
						// unquoted attributes might be urls, so gotta be careful with them and self-closed elements
						!(data[pos] == '/' && pos + 1 < data.length && data[pos+1] == '>') &&
						!data[pos].isSimpleWhite)
							pos++;

					string v = htmlEntitiesDecode(data[start..pos], strict);
					// don't skip the end - we'll need it later
					return v;
			}
		}

		TextNode readTextNode() @safe pure {
			auto start = pos;
			while(pos < data.length && data[pos] != '<') {
				pos++;
			}

			return TextNode.fromUndecodedString(this, data[start..pos]);
		}

		static struct Ele {
			int type; // element or closing tag or nothing
				/*
					type == 0 means regular node, self-closed (element is valid)
					type == 1 means closing tag (payload is the tag name, element may be valid)
					type == 2 means you should ignore it completely
					type == 3 means it is a special element that should be appended, if possible, e.g. a <!DOCTYPE> that was chosen to be kept, php code, or comment. It will be appended at the current element if inside the root, and to a special document area if not
					type == 4 means the document was totally empty
				*/
			Element element; // for type == 0 or type == 3
			string payload; // for type == 1
		}
		// recursively read a tag
		Ele readElement(string[] parentChain = null) @safe pure {
			// FIXME: this is the slowest function in this module, by far, even in strict mode.
			// Loose mode should perform decently, but strict mode is the important one.
			if(!strict && parentChain is null)
				parentChain = [];


			if(pos >= data.length)
			{
				if(strict) {
					throw new MarkupException("Gone over the input (is there no root element or did it never close?), chain: " ~ to!string(parentChain));
				} else {
					if(parentChain.length)
						return Ele(1, null, parentChain[0]); // in loose mode, we just assume the document has ended
					else
						return Ele(4); // signal emptiness upstream
				}
			}

			if(data[pos] != '<') {
				return Ele(0, readTextNode(), null);
			}

			enforce(data[pos] == '<');
			pos++;
			if(pos == data.length) {
				if(strict)
					throw new MarkupException("Found trailing < at end of file");
				// if not strict, we'll just skip the switch
			} else
			switch(data[pos]) {
				// I don't care about these, so I just want to skip them
				case '!': // might be a comment, a doctype, or a special instruction
					pos++;

						// FIXME: we should store these in the tree too
						// though I like having it stripped out tbh.

					if(pos == data.length) {
						if(strict)
							throw new MarkupException("<! opened at end of file");
					} else if(data[pos] == '-' && (pos + 1 < data.length) && data[pos+1] == '-') {
						// comment
						pos += 2;

						// FIXME: technically, a comment is anything
						// between -- and -- inside a <!> block.
						// so in <!-- test -- lol> , the " lol" is NOT a comment
						// and should probably be handled differently in here, but for now
						// I'll just keep running until --> since that's the common way

						auto commentStart = pos;
						while(pos+3 < data.length && data[pos..pos+3] != "-->")
							pos++;

						auto end = commentStart;

						if(pos + 3 >= data.length) {
							if(strict)
								throw new MarkupException("unclosed comment");
							end = data.length;
							pos = data.length;
						} else {
							end = pos;
							assert(data[pos] == '-');
							pos++;
							assert(data[pos] == '-');
							pos++;
							assert(data[pos] == '>');
							pos++;
						}

						if(parseSawComment !is null)
							if(parseSawComment(data[commentStart .. end])) {
								return Ele(3, new HtmlComment(this, data[commentStart .. end]), null);
							}
					} else if(pos + 7 <= data.length && data[pos..pos + 7] == "[CDATA[") {
						pos += 7;

						auto cdataStart = pos;

						ptrdiff_t end = -1;
						typeof(end) cdataEnd;

						if(pos < data.length) {
							// cdata isn't allowed to nest, so this should be generally ok, as long as it is found
							end = data[pos .. $].indexOf("]]>");
						}

						if(end == -1) {
							if(strict)
								throw new MarkupException("Unclosed CDATA section");
							end = pos;
							cdataEnd = pos;
						} else {
							cdataEnd = pos + end;
							pos = cdataEnd + 3;
						}

						return Ele(0, new TextNode(this, data[cdataStart .. cdataEnd]), null);
					} else {
						auto start = pos;
						while(pos < data.length && data[pos] != '>')
							pos++;

						auto bangEnds = pos;
						if(pos == data.length) {
							if(strict)
								throw new MarkupException("unclosed processing instruction (<!xxx>)");
						} else pos++; // skipping the >

						if(parseSawBangInstruction !is null)
							if(parseSawBangInstruction(data[start .. bangEnds])) {
								// FIXME: these should be able to modify the parser state,
								// doing things like adding entities, somehow.

								return Ele(3, new BangInstruction(this, data[start .. bangEnds]), null);
							}
					}

					/*
					if(pos < data.length && data[pos] == '>')
						pos++; // skip the >
					else
						assert(!strict);
					*/
				break;
				case '%':
				case '?':
					/*
						Here's what we want to support:

						<% asp code %>
						<%= asp code %>
						<?php php code ?>
						<?= php code ?>

						The contents don't really matter, just if it opens with
						one of the above for, it ends on the two char terminator.

						<?something>
							this is NOT php code
							because I've seen this in the wild: <?EM-dummyText>

							This could be php with shorttags which would be cut off
							prematurely because if(a >) - that > counts as the close
							of the tag, but since dom.d can't tell the difference
							between that and the <?EM> real world example, it will
							not try to look for the ?> ending.

						The difference between this and the asp/php stuff is that it
						ends on >, not ?>. ONLY <?php or <?= ends on ?>. The rest end
						on >.
					*/

					char end = data[pos];
					auto started = pos;
					bool isAsp = end == '%';
					int currentIndex = 0;
					bool isPhp = false;
					bool isEqualTag = false;
					int phpCount = 0;

				    more:
					pos++; // skip the start
					if(pos == data.length) {
						if(strict)
							throw new MarkupException("Unclosed <"~end~" by end of file");
					} else {
						currentIndex++;
						if(currentIndex == 1 && data[pos] == '=') {
							if(!isAsp)
								isPhp = true;
							isEqualTag = true;
							goto more;
						}
						if(currentIndex == 1 && data[pos] == 'p')
							phpCount++;
						if(currentIndex == 2 && data[pos] == 'h')
							phpCount++;
						if(currentIndex == 3 && data[pos] == 'p' && phpCount == 2)
							isPhp = true;

						if(data[pos] == '>') {
							if((isAsp || isPhp) && data[pos - 1] != end)
								goto more;
							// otherwise we're done
						} else
							goto more;
					}

					//writefln("%s: %s", isAsp ? "ASP" : isPhp ? "PHP" : "<? ", data[started .. pos]);
					auto code = data[started .. pos];


					assert((pos < data.length && data[pos] == '>') || (!strict && pos == data.length));
					if(pos < data.length)
						pos++; // get past the >

					if(isAsp && parseSawAspCode !is null) {
						if(parseSawAspCode(code)) {
							return Ele(3, new AspCode(this, code), null);
						}
					} else if(isPhp && parseSawPhpCode !is null) {
						if(parseSawPhpCode(code)) {
							return Ele(3, new PhpCode(this, code), null);
						}
					} else if(!isAsp && !isPhp && parseSawQuestionInstruction !is null) {
						if(parseSawQuestionInstruction(code)) {
							return Ele(3, new QuestionInstruction(this, code), null);
						}
					}
				break;
				case '/': // closing an element
					pos++; // skip the start
					auto p = pos;
					while(pos < data.length && data[pos] != '>')
						pos++;
					//writefln("</%s>", data[p..pos]);
					if(pos == data.length && data[pos-1] != '>') {
						if(strict)
							throw new MarkupException("File ended before closing tag had a required >");
						else
							data ~= ">"; // just hack it in
					}
					pos++; // skip the '>'

					string tname = data[p..pos-1];
					if(!strict)
						tname = tname.strip;
					if(!caseSensitive)
						tname = tname.toLower();

				return Ele(1, null, tname); // closing tag reports itself here
				case ' ': // assume it isn't a real element...
					if(strict) {
						parseError("bad markup - improperly placed <");
						assert(0); // parseError always throws
					} else
						return Ele(0, TextNode.fromUndecodedString(this, "<"), null);
				default:

					if(!strict) {
						// what about something that kinda looks like a tag, but isn't?
						auto nextTag = data[pos .. $].indexOf("<");
						auto closeTag = data[pos .. $].indexOf(">");
						if(closeTag != -1 && nextTag != -1)
							if(nextTag < closeTag) {
								// since attribute names cannot possibly have a < in them, we'll look for an equal since it might be an attribute value... and even in garbage mode, it'd have to be a quoted one realistically

								auto equal = data[pos .. $].indexOf("=\"");
								if(equal != -1 && equal < closeTag) {
									// this MIGHT be ok, soldier on
								} else {
									// definitely no good, this must be a (horribly distorted) text node
									pos++; // skip the < we're on - don't want text node to end prematurely
									auto node = readTextNode();
									node.contents = "<" ~ node.contents; // put this back
									return Ele(0, node, null);
								}
							}
					}

					string tagName = readTagName();
					string[string] attributes;

					Ele addTag(bool selfClosed) @safe pure {
						if(selfClosed)
							pos++;
						else {
							if(!strict)
								if(tagName.isInArray(selfClosedElements))
									// these are de-facto self closed
									selfClosed = true;
						}

						if(strict) {
						enforce(data[pos] == '>', format("got %s when expecting > (possible missing attribute name)\nContext:\n%s", data[pos], data[max(0, pos - 100) .. min(data.length, pos + 100)]));
						} else {
							// if we got here, it's probably because a slash was in an
							// unquoted attribute - don't trust the selfClosed value
							if(!selfClosed)
								selfClosed = tagName.isInArray(selfClosedElements);

							while(pos < data.length && data[pos] != '>')
								pos++;

							if(pos >= data.length) {
								// the tag never closed
								assert(data.length != 0);
								pos = data.length - 1; // rewinding so it hits the end at the bottom..
							}
						}

						auto whereThisTagStarted = pos; // for better error messages

						pos++;

						auto e = createElement(tagName);
						e.attributes = attributes;
						e.selfClosed = selfClosed;
						e.parseAttributes();


						// HACK to handle script and style as a raw data section as it is in HTML browsers
						if(!pureXmlMode && tagName.isInArray(rawSourceElements)) {
							if(!selfClosed) {
								string closer = "</" ~ tagName ~ ">";
								ptrdiff_t ending;
								if(pos >= data.length)
									ending = -1;
								else
									ending = indexOf(data[pos..$], closer);

								ending = indexOf(data[pos..$], closer, 0, (loose ? CaseSensitive.no : CaseSensitive.yes));
								/*
								if(loose && ending == -1 && pos < data.length)
									ending = indexOf(data[pos..$], closer.toUpper());
								*/
								if(ending == -1) {
									if(strict)
										throw new Exception("tag " ~ tagName ~ " never closed");
									else {
										// let's call it totally empty and do the rest of the file as text. doing it as html could still result in some weird stuff like if(a<4) being read as <4 being a tag so it comes out if(a<4></4> and other weirdness) It is either a closed script tag or the rest of the file is forfeit.
										if(pos < data.length) {
											e = new TextNode(this, data[pos .. $]);
											pos = data.length;
										}
									}
								} else {
									ending += pos;
									e.innerRawSource = data[pos..ending];
									pos = ending + closer.length;
								}
							}
							return Ele(0, e, null);
						}

						bool closed = selfClosed;

						void considerHtmlParagraphHack(Element n) {
							assert(!strict);
							if(e.tagName == "p" && e.tagName == n.tagName) {
								// html lets you write <p> para 1 <p> para 1
								// but in the dom tree, they should be siblings, not children.
								paragraphHackfixRequired = true;
							}
						}

						//writef("<%s>", tagName);
						while(!closed) {
							Ele n;
							if(strict)
								n = readElement();
							else
								n = readElement(parentChain ~ tagName);

							if(n.type == 4) return n; // the document is empty

							if(n.type == 3 && n.element !is null) {
								// special node, append if possible
								if(e !is null)
									processNodeWhileParsing(e, n.element);
								else
									piecesBeforeRoot ~= n.element;
							} else if(n.type == 0) {
								if(!strict)
									considerHtmlParagraphHack(n.element);
								processNodeWhileParsing(e, n.element);
							} else if(n.type == 1) {
								bool found = false;
								if(n.payload != tagName) {
									if(strict)
										parseError(format("mismatched tag: </%s> != <%s> (opened on line %d)", n.payload, tagName, getLineNumber(whereThisTagStarted)));
									else {
										sawImproperNesting = true;
										// this is so we don't drop several levels of awful markup
										if(n.element) {
											if(!strict)
												considerHtmlParagraphHack(n.element);
											processNodeWhileParsing(e, n.element);
											n.element = null;
										}

										// is the element open somewhere up the chain?
										foreach(i, parent; parentChain)
											if(parent == n.payload) {
												recentAutoClosedTags ~= tagName;
												// just rotating it so we don't inadvertently break stuff with vile crap
												if(recentAutoClosedTags.length > 4)
													recentAutoClosedTags = recentAutoClosedTags[1 .. $];

												n.element = e;
												return n;
											}

										// if not, this is a text node; we can't fix it up...

										// If it's already in the tree somewhere, assume it is closed by algorithm
										// and we shouldn't output it - odds are the user just flipped a couple tags
										foreach(ele; e.tree) {
											if(ele.tagName == n.payload) {
												found = true;
												break;
											}
										}

										foreach(ele; recentAutoClosedTags) {
											if(ele == n.payload) {
												found = true;
												break;
											}
										}

										if(!found) // if not found in the tree though, it's probably just text
										processNodeWhileParsing(e, TextNode.fromUndecodedString(this, "</"~n.payload~">"));
									}
								} else {
									if(n.element) {
										if(!strict)
											considerHtmlParagraphHack(n.element);
										processNodeWhileParsing(e, n.element);
									}
								}

								if(n.payload == tagName) // in strict mode, this is always true
									closed = true;
							} else { /*throw new Exception("wtf " ~ tagName);*/ }
						}
						//writef("</%s>\n", tagName);
						return Ele(0, e, null);
					}

					// if a tag was opened but not closed by end of file, we can arrive here
					if(!strict && pos >= data.length)
						return addTag(false);
					//else if(strict) assert(0); // should be caught before

					switch(data[pos]) {
						default: assert(0);
						case '/': // self closing tag
							return addTag(true);
						case '>':
							return addTag(false);
						case ' ':
						case '\t':
						case '\n':
						case '\r':
							// there might be attributes...
							moreAttributes:
							eatWhitespace();

							// same deal as above the switch....
							if(!strict && pos >= data.length)
								return addTag(false);

							if(strict && pos >= data.length)
								throw new MarkupException("tag open, didn't find > before end of file");

							switch(data[pos]) {
								case '/': // self closing tag
									return addTag(true);
								case '>': // closed tag; open -- we now read the contents
									return addTag(false);
								default: // it is an attribute
									string attrName = readAttributeName();
									string attrValue = attrName;

									bool ateAny = eatWhitespace();
									// the spec allows this too, sigh https://www.w3.org/TR/REC-xml/#NT-Eq
									//if(strict && ateAny)
										//throw new MarkupException("inappropriate whitespace after attribute name");

									if(pos >= data.length) {
										if(strict)
											assert(0, "this should have thrown in readAttributeName");
										else {
											data ~= ">";
											goto blankValue;
										}
									}
									if(data[pos] == '=') {
										pos++;

										ateAny = eatWhitespace();
										// the spec actually allows this!
										//if(strict && ateAny)
											//throw new MarkupException("inappropriate whitespace after attribute equals");

										attrValue = readAttributeValue();

										eatWhitespace();
									}

									blankValue:

									if(strict && attrName in attributes)
										throw new MarkupException("Repeated attribute: " ~ attrName);

									if(attrName.strip().length)
										attributes[attrName] = attrValue;
									else if(strict) throw new MarkupException("wtf, zero length attribute name");

									if(!strict && pos < data.length && data[pos] == '<') {
										// this is the broken tag that doesn't have a > at the end
										data = data[0 .. pos] ~ ">" ~ data[pos.. $];
										// let's insert one as a hack
										goto case '>';
									}

									goto moreAttributes;
							}
					}
			}

			return Ele(2, null, null); // this is a <! or <? thing that got ignored prolly.
			//assert(0);
		}

		eatWhitespace();
		Ele r;
		do {
			r = readElement(); // there SHOULD only be one element...

			if(r.type == 3 && r.element !is null)
				piecesBeforeRoot ~= r.element;

			if(r.type == 4)
				break; // the document is completely empty...
		} while (r.type != 0 || r.element.nodeType != 1); // we look past the xml prologue and doctype; root only begins on a regular node

		root = r.element;
		if(root !is null)
			root.parent_ = this;

		unparsed = data[pos .. $];
		if(!strict) { // in strict mode, we'll just ignore stuff after the xml
			while(r.type != 4) {
				r = readElement();
				if(r.type != 4 && r.type != 2) { // if not empty and not ignored
					if(r.element !is null)
						piecesAfterRoot ~= r.element;
				}
			}
		}

		if(root is null)
		{
			if(strict)
				assert(0, "empty document should be impossible in strict mode");
			else
				parseUtf8(`<html><head></head><body></body></html>`); // fill in a dummy document in loose mode since that's what browsers do
		}

		if(paragraphHackfixRequired) {
			assert(!strict); // this should never happen in strict mode; it ought to never set the hack flag...

			// in loose mode, we can see some "bad" nesting (it's valid html, but poorly formed xml).
			// It's hard to handle above though because my code sucks. So, we'll fix it here.

			// Where to insert based on the parent (for mixed closed/unclosed <p> tags). See #120
			// Kind of inefficient because we can't detect when we recurse back out of a node.
			Element[Element] insertLocations;
			auto iterator = root.tree;
			foreach(ele; iterator) {
				if(ele.parentNode is null)
					continue;

				if(ele.tagName == "p" && ele.parentNode.tagName == ele.tagName) {
					auto shouldBePreviousSibling = ele.parentNode;
					auto holder = shouldBePreviousSibling.parentNode; // this is the two element's mutual holder...
					if (auto p = holder in insertLocations) {
						shouldBePreviousSibling = *p;
						assert(shouldBePreviousSibling.parentNode is holder);
					}
					ele = holder.insertAfter(shouldBePreviousSibling, ele.removeFromTree());
					insertLocations[holder] = ele;
					iterator.currentKilled(); // the current branch can be skipped; we'll hit it soon anyway since it's now next up.
				}
			}
		}
	}

	/* end massive parse function */

	/// Gets the <title> element's innerText, if one exists
	@property string title() @safe pure {
		bool doesItMatch(Element e) {
			return (e.tagName == "title");
		}

		auto e = findFirst(&doesItMatch);
		if(e)
			return e.innerText();
		return "";
	}

	/// Sets the title of the page, creating a <title> element if needed.
	@property void title(string t) @safe pure {
		bool doesItMatch(Element e) {
			return (e.tagName == "title");
		}

		auto e = findFirst(&doesItMatch);

		if(!e) {
			e = createElement("title");
			auto heads = getElementsByTagName("head");
			if(heads.length)
				heads[0].appendChild(e);
		}

		if(e)
			e.innerText = t;
	}

	// FIXME: would it work to alias root this; ???? might be a good idea
	/// These functions all forward to the root element. See the documentation in the Element class.
	Element getElementById(string id) @safe pure {
		return root.getElementById(id);
	}

	/// ditto
	final SomeElementType requireElementById(SomeElementType = Element)(string id, string file = __FILE__, size_t line = __LINE__)
		if( is(SomeElementType : Element))
		out(ret) { assert(ret !is null); }
	do {
		return root.requireElementById!(SomeElementType)(id, file, line);
	}

	/// ditto
	final SomeElementType requireSelector(SomeElementType = Element)(string selector, string file = __FILE__, size_t line = __LINE__) @safe pure
		if( is(SomeElementType : Element))
		out(ret) { assert(ret !is null); }
	do {
		auto e = cast(SomeElementType) querySelector(selector);
		if(e is null)
			throw new ElementNotFoundException(SomeElementType.stringof, selector, this.root, file, line);
		return e;
	}

	/// ditto
	final MaybeNullElement!SomeElementType optionSelector(SomeElementType = Element)(string selector, string file = __FILE__, size_t line = __LINE__)
		if(is(SomeElementType : Element))
	{
		auto e = cast(SomeElementType) querySelector(selector);
		return MaybeNullElement!SomeElementType(e);
	}

	/// ditto
	Element querySelector(string selector) @safe pure {
		// see comment below on Document.querySelectorAll
		auto s = Selector(selector);//, !loose);
		foreach(ref comp; s.components)
			if(comp.parts.length && comp.parts[0].separation == 0)
				comp.parts[0].separation = -1;
		foreach(e; s.getMatchingElementsLazy(this.root))
			return e;
		return null;

	}

	/// ditto
	Element[] querySelectorAll(string selector) @safe pure {
		// In standards-compliant code, the document is slightly magical
		// in that it is a pseudoelement at top level. It should actually
		// match the root as one of its children.
		//
		// In versions of dom.d before Dec 29 2019, this worked because
		// querySelectorAll was willing to return itself. With that bug fix
		// (search "arbitrary id asduiwh" in this file for associated unittest)
		// this would have failed. Hence adding back the root if it matches the
		// selector itself.
		//
		// I'd love to do this better later.

		auto s = Selector(selector);//, !loose);
		foreach(ref comp; s.components)
			if(comp.parts.length && comp.parts[0].separation == 0)
				comp.parts[0].separation = -1;
		return s.getMatchingElements(this.root, null);
	}

	/// ditto
	Element[] getElementsByTagName(string tag) @safe pure {
		return root.getElementsByTagName(tag);
	}

	/// ditto
	Element[] getElementsByClassName(string tag) @safe pure {
		return root.getElementsByClassName(tag);
	}

	/** FIXME: btw, this could just be a lazy range...... */
	Element getFirstElementByTagName(string tag) @safe pure {
		if(loose)
			tag = tag.toLower();
		bool doesItMatch(Element e) {
			return e.tagName == tag;
		}
		return findFirst(&doesItMatch);
	}

	/++
		This returns the <body> element, if there is one. (It different than Javascript, where it is called 'body', because body used to be a keyword in D.)

		History:
			`body` alias added February 26, 2024
	+/
	Element mainBody() @safe pure {
		return getFirstElementByTagName("body");
	}

	/// ditto
	alias body = mainBody;

	/// this uses a weird thing... it's [name=] if no colon and
	/// [property=] if colon
	string getMeta(string name) @safe pure {
		string thing = name.indexOf(":") == -1 ? "name" : "property";
		auto e = querySelector("head meta["~thing~"="~name~"]");
		if(e is null)
			return null;
		return e.getAttribute("content");
	}

	/// Sets a meta tag in the document header. It is kinda hacky to work easily for both Facebook open graph and traditional html meta tags/
	void setMeta(string name, string value) @safe pure {
		string thing = name.indexOf(":") == -1 ? "name" : "property";
		auto e = querySelector("head meta["~thing~"="~name~"]");
		if(e is null) {
			e = requireSelector("head").addChild("meta");
			e.setAttribute(thing, name);
		}

		e.setAttribute("content", value);
	}

	///.
	Form createForm() @safe pure
		out(ret) {
			assert(ret !is null);
		}
	do {
		return cast(Form) createElement("form");
	}

	///.
	Element createElement(string name) @safe pure {
		if(loose)
			name = name.toLower();

		auto e = Element.make(name, null, null, selfClosedElements);

		return e;

//		return new Element(this, name, null, selfClosed);
	}

	///.
	Element createFragment() @safe pure {
		return new DocumentFragment(this);
	}

	///.
	Element createTextNode(string content) @safe pure {
		return new TextNode(this, content);
	}


	///.
	Element findFirst(bool delegate(Element) @safe pure doesItMatch) @safe pure {
		if(root is null)
			return null;
		Element result;

		bool goThroughElement(Element e) {
			if(doesItMatch(e)) {
				result = e;
				return true;
			}

			foreach(child; e.children) {
				if(goThroughElement(child))
					return true;
			}

			return false;
		}

		goThroughElement(root);

		return result;
	}

	///.
	void clear() @safe pure {
		root = null;
		loose = false;
	}

	private string _prolog = "<!DOCTYPE html>\n";
	private bool prologWasSet = false; // set to true if the user changed it

	/++
		Returns or sets the string before the root element. This is, for example,
		`<!DOCTYPE html>\n` or similar.
	+/
	@property string prolog() const @safe pure {
		// if the user explicitly changed it, do what they want
		// or if we didn't keep/find stuff from the document itself,
		// we'll use the builtin one as a default.
		if(prologWasSet || piecesBeforeRoot.length == 0)
			return _prolog;

		string p;
		foreach(e; piecesBeforeRoot)
			p ~= e.toString() ~ "\n";
		return p;
	}

	/// ditto
	void setProlog(string d) @safe pure {
		_prolog = d;
		prologWasSet = true;
	}

	/++
		Returns the document as string form. Please note that if there is anything in [piecesAfterRoot],
		they are discarded. If you want to add them to the file, loop over that and append it yourself
		(but remember xml isn't supposed to have anything after the root element).
	+/
	override string toString() const @safe pure {
		return prolog ~ root.toString();
	}

	/++
		Writes it out with whitespace for easier eyeball debugging

		Do NOT use for anything other than eyeball debugging,
		because whitespace may be significant content in XML.
	+/
	string toPrettyString(bool insertComments = false, int indentationLevel = 0, string indentWith = "\t") const @safe pure {
		string s = prolog.strip;

		/*
		if(insertComments) s ~= "<!--";
		s ~= "\n";
		if(insertComments) s ~= "-->";
		*/

		s ~= root.toPrettyStringImpl(insertComments, indentationLevel, indentWith);
		foreach(a; piecesAfterRoot)
			s ~= a.toPrettyStringImpl(insertComments, indentationLevel, indentWith);
		return s;
	}

	/// The root element, like `<html>`. Most the methods on Document forward to this object.
	Element root;

	/// if these were kept, this is stuff that appeared before the root element, such as <?xml version ?> decls and <!DOCTYPE>s
	Element[] piecesBeforeRoot;

	/// stuff after the root, only stored in non-strict mode and not used in toString, but available in case you want it
	Element[] piecesAfterRoot;
	/// Ditto, but unparsed
	string unparsed;

	///.
	bool loose;
}

/++
	Basic parsing of HTML tag soup

	If you simply make a `new Document("some string")`,
	the Document parser will assume it is broken HTML. It will try to fix up things like charset messes, missing
	closing tags, flipped tags, inconsistent letter cases, and other forms of commonly found HTML on the web.

	It isn't exactly the same as what a HTML5 web browser does in all cases, but it usually it, and where it
	disagrees, it is still usually good enough (but sometimes a bug).
+/
@safe pure unittest {
	auto document = new Document(`<html><body><p>hello <P>there`);
	// this will automatically try to normalize the html and fix up broken tags, etc
	// so notice how it added the missing closing tags here and made them all lower case
	assert(document.toString() == "<!DOCTYPE html>\n<html><body><p>hello </p><p>there</p></body></html>", document.toString());
}

/++
	Stricter parsing of HTML

	When you are writing the HTML yourself, you can remove most ambiguity by making it throw exceptions instead
	of trying to automatically fix up things basic parsing tries to do. Using strict mode accomplishes this.

	This will help guarantee that you have well-formed HTML, which means it is going to parse a lot more reliably
	by all users - browsers, dom.d, other libraries, all behave better with well-formed input... people too!

	(note it is not a full *validator*, just a well-formedness checker. Full validation is a lot more work for very
	little benefit in my experience, so I stopped here.)
+/
@safe pure unittest {
	try {
		auto document = new Document(`<html><body><p>hello <P>there`, true, true); // turns on strict and case sensitive mode to ctor
		assert(0); // never reached, the constructor will throw because strict mode is turned on
	} catch(Exception e) {

	}

	// you can also create the object first, then use the [parseStrict] method
	auto document = new Document;
	document.parseStrict(`<foo></foo>`); // this is invalid html - no such foo tag - but it is well-formed, since it is opened and closed properly, so it passes

}

/++
	Custom HTML extensions

	dom.d is a custom HTML parser, which means you can add custom HTML extensions to it too. It normally reads
	and discards things like ASP style `<% ... %>` code as well as XML processing instruction / PHP style embeds `<? ... ?>`
	but you can keep this data if you call a function to opt into it in before parsing.

	Additionally, you can add special tags to be read like `<script>` to preserve its insides for future processing
	via the `.innerRawSource` member.
+/
@safe pure unittest {
	auto document = new Document; // construct an empty thing first
	document.enableAddingSpecialTagsToDom(); // add the special tags like <% ... %> etc
	document.rawSourceElements ~= "embedded-plaintext"; // tell it we want a custom

	document.parseStrict(`<html>
		<% some asp code %>
		<script>embedded && javascript</script>
		<embedded-plaintext>my <custom> plaintext & stuff</embedded-plaintext>
	</html>`);

	// please note that if we did `document.toString()` right now, the original source - almost your same
	// string you passed to parseStrict - would be spit back out. Meaning the embedded-plaintext still has its
	// special text inside it. Another parser won't understand how to use this! So if you want to pass this
	// document somewhere else, you need to do some transformations.
	//
	// This differs from cases like CDATA sections, which dom.d will automatically convert into plain html entities
	// on the output that can be read by anyone.

	assert(document.root.tagName == "html"); // the root element is normal

	int foundCount;
	// now let's loop through the whole tree
	foreach(element; document.root.tree) {
		// the asp thing will be in
		if(auto asp = cast(AspCode) element) {
			// you use the `asp.source` member to get the code for these
			assert(asp.source == "% some asp code %");
			foundCount++;
		} else if(element.tagName == "script") {
			// and for raw source elements - script, style, or the ones you add,
			// you use the innerHTML method to get the code inside
			assert(element.innerHTML == "embedded && javascript");
			foundCount++;
		} else if(element.tagName == "embedded-plaintext") {
			// and innerHTML again
			assert(element.innerHTML == "my <custom> plaintext & stuff");
			foundCount++;
		}

	}

	assert(foundCount == 3);

	// writeln(document.toString());
}

// FIXME: <textarea> contents are treated kinda special in html5 as well...

/++
	Demoing CDATA, entities, and non-ascii characters.

	The previous example mentioned CDATA, let's show you what that does too. These are all read in as plain strings accessible in the DOM - there is no CDATA, no entities once you get inside the object model - but when you convert back into a string, it will normalize them in a particular way.

	This is not exactly standards compliant completely in and out thanks to it doing some transformations... but I find it more useful - it reads the data in consistently and writes it out consistently, both in ways that work well for interop. Take a look:
+/
@safe pure unittest {
	auto document = new Document(`<html>
		<p>¤ is a non-ascii character. It will be converted to a numbered entity in string output.</p>
		<p>&curren; is the same thing, but as a named entity. It also will be changed to a numbered entity in string output.</p>
		<p><![CDATA[xml cdata segments, which can contain <tag> looking things, are converted to encode the embedded special-to-xml characters to entities too.]]></p>
	</html>`, true, true); // strict mode turned on

	// Inside the object model, things are simplified to D strings.
	auto paragraphs = document.querySelectorAll("p");
	// no surprise on the first paragraph, we wrote it with the character, and it is still there in the D string
	assert(paragraphs[0].textContent == "¤ is a non-ascii character. It will be converted to a numbered entity in string output.");
	// but note on the second paragraph, the entity has been converted to the appropriate *character* in the object
	assert(paragraphs[1].textContent == "¤ is the same thing, but as a named entity. It also will be changed to a numbered entity in string output.");
	// and the CDATA bit is completely gone from the DOM; it just read it in as a text node. The txt content shows the text as a plain string:
	assert(paragraphs[2].textContent == "xml cdata segments, which can contain <tag> looking things, are converted to encode the embedded special-to-xml characters to entities too.");
	// and the dom node beneath it is just a single text node; no trace of the original CDATA detail is left after parsing.
	assert(paragraphs[2].childNodes.length == 1 && paragraphs[2].childNodes[0].nodeType == NodeType.Text);

	// And now, in the output string, we can see they are normalized thusly:
	assert(document.toString() == "<!DOCTYPE html>\n<html>
		<p>&#164; is a non-ascii character. It will be converted to a numbered entity in string output.</p>
		<p>&#164; is the same thing, but as a named entity. It also will be changed to a numbered entity in string output.</p>
		<p>xml cdata segments, which can contain &lt;tag&gt; looking things, are converted to encode the embedded special-to-xml characters to entities too.</p>
	</html>");
}

/++
	Streaming parsing

	dom.d normally takes a big string and returns a big DOM object tree - hence its name. This is usually the simplest
	code to read and write, so I prefer to stick to that, but if you wanna jump through a few hoops, you can still make
	dom.d work with streams.

	It is awkward - again, dom.d's whole design is based on building the dom tree, but you can do it if you're willing to
	subclass a little and trust the garbage collector. Here's how.
+/
@safe pure unittest {
	bool encountered;
	class StreamDocument : Document {
		// the normal behavior for this function is to `parent.appendChild(child)`
		// but we can override to read it as it is processed and not append it
		override void processNodeWhileParsing(Element parent, Element child) @safe pure {
			if(child.tagName == "bar")
				encountered = true;
			// note that each element's object is created but then discarded as garbage.
			// the GC will take care of it, even with a large document, whereas the normal
			// object tree could become quite large.
		}

		this() {
			super("<foo><bar></bar></foo>");
		}
	}

	auto test = new StreamDocument();
	assert(encountered); // it should have been seen
	assert(test.querySelector("bar") is null); // but not appended to the dom node, since we didn't append it
}

/++
	Basic parsing of XML.

	dom.d is not technically a standards-compliant xml parser and doesn't implement all xml features,
	but its stricter parse options together with turning off HTML's special tag handling (e.g. treating
	`<script>` and `<style>` the same as any other tag) gets close enough to work fine for a great many
	use cases.

	For more information, see [XmlDocument].
+/
@safe pure unittest {
	auto xml = new XmlDocument(`<my-stuff>hello</my-stuff>`);
}

interface DomParent {
	inout(Document) asDocument() inout @safe pure;
	inout(Element) asElement() inout @safe pure;
}

/++
	This represents almost everything in the DOM and offers a lot of inspection and manipulation functions. Element, or its subclasses, are what makes the dom tree.
+/
/// Group: core_functionality
class Element : DomParent {
	inout(Document) asDocument() inout @safe pure { return null; }
	inout(Element) asElement() inout @safe pure { return this; }

	/// Returns a collection of elements by selector.
	/// See: [Document.opIndex]
	ElementCollection opIndex(string selector) @safe pure {
		auto e = ElementCollection(this);
		return e[selector];
	}

	/++
		Returns the child node with the particular index.

		Be aware that child nodes include text nodes, including
		whitespace-only nodes.
	+/
	Element opIndex(size_t index) @safe pure {
		if(index >= children.length)
			return null;
		return this.children[index];
	}

	/// Calls getElementById, but throws instead of returning null if the element is not found. You can also ask for a specific subclass of Element to dynamically cast to, which also throws if it cannot be done.
	final SomeElementType requireElementById(SomeElementType = Element)(string id, string file = __FILE__, size_t line = __LINE__)
	if(
		is(SomeElementType : Element)
	)
	out(ret) {
		assert(ret !is null);
	}
	do {
		auto e = cast(SomeElementType) getElementById(id);
		if(e is null)
			throw new ElementNotFoundException(SomeElementType.stringof, "id=" ~ id, this, file, line);
		return e;
	}

	/// ditto but with selectors instead of ids
	final SomeElementType requireSelector(SomeElementType = Element)(string selector, string file = __FILE__, size_t line = __LINE__)
	if(
		is(SomeElementType : Element)
	)
	out(ret) {
		assert(ret !is null);
	}
	do {
		auto e = cast(SomeElementType) querySelector(selector);
		if(e is null)
			throw new ElementNotFoundException(SomeElementType.stringof, selector, this, file, line);
		return e;
	}


	/++
		If a matching selector is found, it returns that Element. Otherwise, the returned object returns null for all methods.
	+/
	final MaybeNullElement!SomeElementType optionSelector(SomeElementType = Element)(string selector, string file = __FILE__, size_t line = __LINE__)
		if(is(SomeElementType : Element))
	{
		auto e = cast(SomeElementType) querySelector(selector);
		return MaybeNullElement!SomeElementType(e);
	}



	/// get all the classes on this element
	@property string[] classes() const @safe pure {
		// FIXME: remove blank names
		auto cs = split(className, " ");
		foreach(ref c; cs)
			c = c.strip();
		return cs;
	}

	/++
		The object [classList] returns.
	+/
	static struct ClassListHelper {
		Element this_;
		this(inout(Element) this_) inout @safe pure {
			this.this_ = this_;
		}

		///
		bool contains(string cn) const @safe pure {
			return this_.hasClass(cn);
		}

		///
		void add(string cn) @safe pure {
			this_.addClass(cn);
		}

		///
		void remove(string cn) @safe pure {
			this_.removeClass(cn);
		}

		///
		void toggle(string cn) @safe pure {
			if(contains(cn))
				remove(cn);
			else
				add(cn);
		}

		// this thing supposed to be iterable in javascript but idk how i want to do it in D. meh
		/+
		string[] opIndex() const {
			return this_.classes;
		}
		+/
	}

	/++
		Returns a helper object to work with classes, just like javascript.

		History:
			Added August 25, 2022
	+/
	@property inout(ClassListHelper) classList() inout @safe pure {
		return inout(ClassListHelper)(this);
	}
	// FIXME: classList is supposed to whitespace and duplicates when you use it. need to test.

	@safe pure unittest {
		Element element = Element.make("div");
		element.classList.add("foo");
		assert(element.classList.contains("foo"));
		element.classList.remove("foo");
		assert(!element.classList.contains("foo"));
		element.classList.toggle("bar");
		assert(element.classList.contains("bar"));
	}

	/// ditto
	alias classNames = classes;


	/// Adds a string to the class attribute. The class attribute is used a lot in CSS.
	Element addClass(string c) @safe pure {
		if(hasClass(c))
			return this; // don't add it twice

		string cn = getAttribute("class");
		if(cn.length == 0) {
			setAttribute("class", c);
			return this;
		} else {
			setAttribute("class", cn ~ " " ~ c);
		}

		return this;
	}

	/// Removes a particular class name.
	Element removeClass(string c) @safe pure {
		if(!hasClass(c))
			return this;
		string n;
		foreach(name; classes) {
			if(c == name)
				continue; // cut it out
			if(n.length)
				n ~= " ";
			n ~= name;
		}

		className = n.strip();

		return this;
	}

	/// Returns whether the given class appears in this element.
	bool hasClass(string c) const @safe pure {
		string cn = className;

		auto idx = cn.indexOf(c);
		if(idx == -1)
			return false;

		foreach(cla; cn.split(" "))
			if(cla.strip == c)
				return true;
		return false;

		/*
		int rightSide = idx + c.length;

		bool checkRight() {
			if(rightSide == cn.length)
				return true; // it's the only class
			else if(iswhite(cn[rightSide]))
				return true;
			return false; // this is a substring of something else..
		}

		if(idx == 0) {
			return checkRight();
		} else {
			if(!iswhite(cn[idx - 1]))
				return false; // substring
			return checkRight();
		}

		assert(0);
		*/
	}


	/* *******************************
		  DOM Mutation
	*********************************/
	/++
		Family of convenience functions to quickly add a tag with some text or
		other relevant info (for example, it's a src for an <img> element
		instead of inner text). They forward to [Element.make] then calls [appendChild].

		---
		div.addChild("span", "hello there");
		div.addChild("div", Html("<p>children of the div</p>"));
		---
	+/
	Element addChild(string tagName, string childInfo = null, string childInfo2 = null) @safe pure
		in {
			assert(tagName !is null);
		}
		out(e) {
			//assert(e.parentNode is this);
			//assert(e.parentDocument is this.parentDocument);
		}
	do {
		auto e = Element.make(tagName, childInfo, childInfo2);
		// FIXME (maybe): if the thing is self closed, we might want to go ahead and
		// return the parent. That will break existing code though.
		return appendChild(e);
	}

	/// ditto
	Element addChild(Element e) @safe pure {
		return this.appendChild(e);
	}

	/// ditto
	Element addChild(string tagName, Element firstChild, string info2 = null) @safe pure
	in {
		assert(firstChild !is null);
	}
	out(ret) {
		assert(ret !is null);
		assert(ret.parentNode is this);
		assert(firstChild.parentNode is ret);

		assert(ret.parentDocument is this.parentDocument);
		//assert(firstChild.parentDocument is this.parentDocument);
	}
	do {
		auto e = Element.make(tagName, "", info2);
		e.appendChild(firstChild);
		this.appendChild(e);
		return e;
	}

	/// ditto
	Element addChild(string tagName, in Html innerHtml, string info2 = null) @safe pure
	in {
	}
	out(ret) {
		assert(ret !is null);
		assert((ret.parentNode is this), ret.toString);// e.parentNode ? e.parentNode.toString : "null");
		assert(ret.parentDocument is this.parentDocument);
	}
	do {
		auto e = Element.make(tagName, "", info2);
		this.appendChild(e);
		e.innerHTML = innerHtml.source;
		return e;
	}


	/// Another convenience function. Adds a child directly after the current one, returning
	/// the new child.
	///
	/// Between this, addChild, and parentNode, you can build a tree as a single expression.
	/// See_Also: [addChild]
	Element addSibling(string tagName, string childInfo = null, string childInfo2 = null) @safe pure
		in {
			assert(tagName !is null);
			assert(parentNode !is null);
		}
		out(e) {
			assert(e.parentNode is this.parentNode);
			assert(e.parentDocument is this.parentDocument);
		}
	do {
		auto e = Element.make(tagName, childInfo, childInfo2);
		return parentNode.insertAfter(this, e);
	}

	/// ditto
	Element addSibling(Element e) @safe pure {
		return parentNode.insertAfter(this, e);
	}

	/// Convenience function to append text intermixed with other children.
	/// For example: div.addChildren("You can visit my website by ", new Link("mysite.com", "clicking here"), ".");
	/// or div.addChildren("Hello, ", user.name, "!");
	/// See also: appendHtml. This might be a bit simpler though because you don't have to think about escaping.
	void addChildren(T...)(T t) {
		foreach(item; t) {
			static if(is(item : Element))
				appendChild(item);
			else static if (is(isSomeString!(item)))
				appendText(to!string(item));
			else static assert(0, "Cannot pass " ~ typeof(item).stringof ~ " to addChildren");
		}
	}

	/// Appends the list of children to this element.
	void appendChildren(Element[] children) @safe pure {
		foreach(ele; children)
			appendChild(ele);
	}

	/// Removes this element form its current parent and appends it to the given `newParent`.
	void reparent(Element newParent) @safe pure
		in(newParent !is null)
		in(parentNode !is null)
		out(;this.parentNode is newParent)
		//out(;isInArray(this, newParent.children))
	{
		parentNode.removeChild(this);
		newParent.appendChild(this);
	}

	/**
		Strips this tag out of the document, putting its inner html
		as children of the parent.

		For example, given: `<p>hello <b>there</b></p>`, if you
		call `stripOut` on the `b` element, you'll be left with
		`<p>hello there<p>`.

		The idea here is to make it easy to get rid of garbage
		markup you aren't interested in.
	*/
	void stripOut() @safe pure
		in(parentNode !is null)
		out(;parentNode is null)
		out(;children.length == 0)
	{
		foreach(c; children)
			c.parentNode = null; // remove the parent
		if(children.length)
			parentNode.replaceChild(this, this.children);
		else
			parentNode.removeChild(this);
		this.children.length = 0; // we reparented them all above
	}

	/// shorthand for `this.parentNode.removeChild(this)` with `parentNode` `null` check
	/// if the element already isn't in a tree, it does nothing.
	Element removeFromTree() @safe pure
		in {

		}
		out(var) {
			assert(this.parentNode is null);
			assert(var is this);
		}
	do {
		if(this.parentNode is null)
			return this;

		this.parentNode.removeChild(this);

		return this;
	}

	/++
		Wraps this element inside the given element.
		It's like `this.replaceWith(what); what.appendchild(this);`

		Given: `<b>cool</b>`, if you call `b.wrapIn(new Link("site.com", "my site is "));`
		you'll end up with: `<a href="site.com">my site is <b>cool</b></a>`.
	+/
	Element wrapIn(Element what) @safe pure
		in {
			assert(what !is null);
		}
		out(ret) {
			assert(this.parentNode is what);
			assert(ret is what);
		}
	do {
		this.replaceWith(what);
		what.appendChild(this);

		return what;
	}

	/// Replaces this element with something else in the tree.
	Element replaceWith(Element e) @safe pure
	in {
		assert(this.parentNode !is null);
	}
	do {
		e.removeFromTree();
		this.parentNode.replaceChild(this, e);
		return e;
	}

	/**
		Fetches the first consecutive text nodes concatenated together.


		`firstInnerText` of `<example>some text<span>more text</span></example>` is `some text`. It stops at the first child tag encountered.

		See_also: [directText], [innerText]
	*/
	string firstInnerText() const @safe pure {
		string s;
		foreach(child; children) {
			if(child.nodeType != NodeType.Text)
				break;

			s ~= child.nodeValue();
		}
		return s;
	}


	/**
		Returns the text directly under this element.


		Unlike [innerText], it does not recurse, and unlike [firstInnerText], it continues
		past child tags. So, `<example>some <b>bold</b> text</example>`
		will return `some  text` because it only gets the text, skipping non-text children.

		See_also: [firstInnerText], [innerText]
	*/
	@property string directText() @safe pure {
		string ret;
		foreach(e; children) {
			if(e.nodeType == NodeType.Text)
				ret ~= e.nodeValue();
		}

		return ret;
	}

	/**
		Sets the direct text, without modifying other child nodes.


		Unlike [innerText], this does *not* remove existing elements in the element.

		It only replaces the first text node it sees.

		If there are no text nodes, it calls [appendText].

		So, given `<div><img />text here</div>`, it will keep the `<img />`, and replace the `text here`.
	*/
	@property void directText(string text) @safe pure {
		foreach(e; children) {
			if(e.nodeType == NodeType.Text) {
				auto it = cast(TextNode) e;
				it.contents = text;
				return;
			}
		}

		appendText(text);
	}

	// do nothing, this is primarily a virtual hook
	// for links and forms
	void setValue(string field, string value) @safe pure { }

	// putting all the members up front

	// this ought to be private. don't use it directly.
	Element[] children;

	/// The name of the tag. Remember, changing this doesn't change the dynamic type of the object.
	string tagName;

	/// This is where the attributes are actually stored. You should use getAttribute, setAttribute, and hasAttribute instead.
	string[string] attributes;

	/// In XML, it is valid to write <tag /> for all elements with no children, but that breaks HTML, so I don't do it here.
	/// Instead, this flag tells if it should be. It is based on the source document's notation and a html element list.
	private bool selfClosed;

	private DomParent parent_;

	/// Get the parent Document object that contains this element.
	/// It may be null, so remember to check for that.
	@property inout(Document) parentDocument() inout @trusted pure {
		if(this.parent_ is null)
			return null;
		auto p = cast() this.parent_.asElement;
		auto prev = cast() this;
		while(p) {
			prev = p;
			if(p.parent_ is null)
				return null;
			p = cast() p.parent_.asElement;
		}
		return cast(inout) prev.parent_.asDocument;
	}

	/*deprecated*/ @property void parentDocument(Document doc) @safe pure {
		parent_ = doc;
	}

	/// Returns the parent node in the tree this element is attached to.
	inout(Element) parentNode() inout @safe pure {
		if(parent_ is null)
			return null;

		return parent_.asElement;
	}

	//protected
	Element parentNode(Element e) @safe pure {
		parent_ = e;
		return e;
	}

	// and now methods

	/++
		Convenience function to try to do the right thing for HTML. This is the main way I create elements.

		History:
			On February 8, 2021, the `selfClosedElements` parameter was added. Previously, it used a private
			immutable global list for HTML. It still defaults to the same list, but you can change it now via
			the parameter.
		See_Also:
			[addChild], [addSibling]
	+/
	static Element make(string tagName, string childInfo = null, string childInfo2 = null, const string[] selfClosedElements = htmlSelfClosedElements) @safe pure {
		bool selfClosed = tagName.isInArray(selfClosedElements);

		Element e;
		// want to create the right kind of object for the given tag...
		switch(tagName) {
			case "#text":
				e = new TextNode(null, childInfo);
				return e;
			// break;
			case "table":
				e = new Table(null);
			break;
			case "a":
				e = new Link(null);
			break;
			case "form":
				e = new Form(null);
			break;
			case "tr":
				e = new TableRow(null);
			break;
			case "td", "th":
				e = new TableCell(null, tagName);
			break;
			default:
				e = new Element(null, tagName, null, selfClosed); // parent document should be set elsewhere
		}

		// make sure all the stuff is constructed properly FIXME: should probably be in all the right constructors too
		e.tagName = tagName;
		e.selfClosed = selfClosed;

		if(childInfo !is null)
			switch(tagName) {
				/* html5 convenience tags */
				case "audio":
					if(childInfo.length)
						e.addChild("source", childInfo);
					if(childInfo2 !is null)
						e.appendText(childInfo2);
				break;
				case "source":
					e.setAttribute("src", childInfo);
					if(childInfo2 !is null)
						e.setAttribute("type", childInfo2);
				break;
				/* regular html 4 stuff */
				case "img":
					e.setAttribute("src", childInfo);
					if(childInfo2 !is null)
						e.setAttribute("alt", childInfo2);
				break;
				case "link":
					e.setAttribute("href", childInfo);
					if(childInfo2 !is null)
						e.setAttribute("rel", childInfo2);
				break;
				case "option":
					e.innerText = childInfo;
					if(childInfo2 !is null)
						e.setAttribute("value", childInfo2);
				break;
				case "input":
					e.setAttribute("type", "hidden");
					e.setAttribute("name", childInfo);
					if(childInfo2 !is null)
						e.setAttribute("value", childInfo2);
				break;
				case "button":
					e.innerText = childInfo;
					if(childInfo2 !is null)
						e.setAttribute("type", childInfo2);
				break;
				case "a":
					e.innerText = childInfo;
					if(childInfo2 !is null)
						e.setAttribute("href", childInfo2);
				break;
				case "script":
				case "style":
					e.innerRawSource = childInfo;
				break;
				case "meta":
					e.setAttribute("name", childInfo);
					if(childInfo2 !is null)
						e.setAttribute("content", childInfo2);
				break;
				/* generically, assume we were passed text and perhaps class */
				default:
					e.innerText = childInfo;
					if(childInfo2.length)
						e.className = childInfo2;
			}

		return e;
	}

	/// ditto
	static Element make(string tagName, in Html innerHtml, string childInfo2 = null) @safe pure {
		// FIXME: childInfo2 is ignored when info1 is null
		auto m = Element.make(tagName, "not null"[0..0], childInfo2);
		m.innerHTML = innerHtml.source;
		return m;
	}

	/// ditto
	static Element make(string tagName, Element child, string childInfo2 = null) @safe pure {
		auto m = Element.make(tagName, cast(string) null, childInfo2);
		m.appendChild(child);
		return m;
	}


	/// Generally, you don't want to call this yourself - use Element.make or document.createElement instead.
	this(Document _parentDocument, string _tagName, string[string] _attributes = null, bool _selfClosed = false) @safe pure {
		tagName = _tagName;
		if(_attributes !is null)
			attributes = _attributes;
		selfClosed = _selfClosed;

		assert(_tagName.indexOf(" ") == -1);//, "<" ~ _tagName ~ "> is invalid");
	}

	/++
		Convenience constructor when you don't care about the parentDocument. Note this might break things on the document.
		Note also that without a parent document, elements are always in strict, case-sensitive mode.

		History:
			On February 8, 2021, the `selfClosedElements` parameter was added. It defaults to the same behavior as
			before: using the hard-coded list of HTML elements, but it can now be overridden. If you use
			[Document.createElement], it will use the list set for the current document. Otherwise, you can pass
			something here if you like.
	+/
	this(string _tagName, string[string] _attributes = null, const string[] selfClosedElements = htmlSelfClosedElements) @safe pure {
		tagName = _tagName;
		if(_attributes !is null)
			attributes = _attributes;
		selfClosed = tagName.isInArray(selfClosedElements);

		// this is meant to reserve some memory. It makes a small, but consistent improvement.
		//children.length = 8;
		//children.length = 0;
	}

	private this(Document _parentDocument) @safe pure {}


	/* *******************************
	       Navigating the DOM
	*********************************/

	/// Returns the first child of this element. If it has no children, returns null.
	/// Remember, text nodes are children too.
	@property Element firstChild() @safe pure {
		return children.length ? children[0] : null;
	}

	/// Returns the last child of the element, or null if it has no children. Remember, text nodes are children too.
	@property Element lastChild() @safe pure {
		return children.length ? children[$ - 1] : null;
	}

	// FIXME UNTESTED
	/// the next or previous element you would encounter if you were reading it in the source. May be a text node or other special non-tag object if you enabled them.
	Element nextInSource() @safe pure {
		auto n = firstChild;
		if(n is null)
			n = nextSibling();
		if(n is null) {
			auto p = this.parentNode;
			while(p !is null && n is null) {
				n = p.nextSibling;
			}
		}

		return n;
	}

	/// ditto
	Element previousInSource() @safe pure {
		auto p = previousSibling;
		if(p is null) {
			auto par = parentNode;
			if(par)
				p = par.lastChild;
			if(p is null)
				p = par;
		}
		return p;
	}

	/++
		Returns the next or previous sibling that is not a text node. Please note: the behavior with comments is subject to change. Currently, it will return a comment or other nodes if it is in the tree (if you enabled it with [Document.enableAddingSpecialTagsToDom] or [Document.parseSawComment]) and not if you didn't, but the implementation will probably change at some point to skip them regardless.

		Equivalent to [previousSibling]/[nextSibling]("*").

		Please note it may return `null`.
	+/
	@property Element previousElementSibling() @safe pure {
		return previousSibling("*");
	}

	/// ditto
	@property Element nextElementSibling() @safe pure {
		return nextSibling("*");
	}

	/++
		Returns the next or previous sibling matching the `tagName` filter. The default filter of `null` will return the first sibling it sees, even if it is a comment or text node, or anything else. A filter of `"*"` will match any tag with a name. Otherwise, the string must match the [tagName] of the sibling you want to find.
	+/
	@property Element previousSibling(string tagName = null) @safe pure {
		if(this.parentNode is null)
			return null;
		Element ps = null;
		foreach(e; this.parentNode.childNodes) {
			if(e is this)
				break;
			if(tagName == "*" && e.nodeType != NodeType.Text) {
				ps = e;
			} else if(tagName is null || e.tagName == tagName)
				ps = e;
		}

		return ps;
	}

	/// ditto
	@property Element nextSibling(string tagName = null) @safe pure {
		if(this.parentNode is null)
			return null;
		Element ns = null;
		bool mightBe = false;
		foreach(e; this.parentNode.childNodes) {
			if(e is this) {
				mightBe = true;
				continue;
			}
			if(mightBe) {
				if(tagName == "*" && e.nodeType != NodeType.Text) {
					ns = e;
					break;
				}
				if(tagName is null || e.tagName == tagName) {
					ns = e;
					break;
				}
			}
		}

		return ns;
	}


	/++
		Gets the nearest node, going up the chain, with the given tagName
		May return null or throw. The type `T` will specify a subclass like
		[Form], [Table], or [Link], which it will cast for you when found.
	+/
	T getParent(T = Element)(string tagName = null) if(is(T : Element)) {
		if(tagName is null) {
			static if(is(T == Form))
				tagName = "form";
			else static if(is(T == Table))
				tagName = "table";
			else static if(is(T == Link))
				tagName == "a";
		}

		auto par = this.parentNode;
		while(par !is null) {
			if(tagName is null || par.tagName == tagName)
				break;
			par = par.parentNode;
		}

		static if(!is(T == Element)) {
			auto t = cast(T) par;
			if(t is null)
				throw new ElementNotFoundException("", tagName ~ " parent not found", this);
		} else
			auto t = par;

		return t;
	}

	/++
		Searches this element and the tree of elements under it for one matching the given `id` attribute.
	+/
	Element getElementById(string id) @safe pure {
		// FIXME: I use this function a lot, and it's kinda slow
		// not terribly slow, but not great.
		foreach(e; tree)
			if(e.getAttribute("id") == id)
				return e;
		return null;
	}

	/++
		Returns a child element that matches the given `selector`.

		Note: you can give multiple selectors, separated by commas.
	 	It will return the first match it finds.

		Tip: to use namespaces, escape the colon in the name:

		---
			element.querySelector(`ns\:tag`); // the backticks are raw strings then the backslash is interpreted by querySelector
		---
	+/
	Element querySelector(string selector) @safe pure {
		Selector s = Selector(selector);

		foreach(ref comp; s.components)
			if(comp.parts.length && comp.parts[0].separation > 0) {
				// this is illegal in standard dom, but i use it a lot
				// gonna insert a :scope thing

				SelectorPart part;
				part.separation = -1;
				part.scopeElement = true;
				comp.parts = part ~ comp.parts;
			}

		foreach(ele; tree)
			if(s.matchesElement(ele, this))
				return ele;
		return null;
	}

	/// If the element matches the given selector. Previously known as `matchesSelector`.
	bool matches(string selector) @safe pure {
		/+
		bool caseSensitiveTags = true;
		if(parentDocument && parentDocument.loose)
			caseSensitiveTags = false;
		+/

		Selector s = Selector(selector);
		return s.matchesElement(this);
	}

	/// Returns itself or the closest parent that matches the given selector, or null if none found
	/// See_also: https://developer.mozilla.org/en-US/docs/Web/API/Element/closest
	Element closest(string selector) @safe pure {
		Element e = this;
		while(e !is null) {
			if(e.matches(selector))
				return e;
			e = e.parentNode;
		}
		return null;
	}

	/**
		Returns elements that match the given CSS selector

		* -- all, default if nothing else is there

		tag#id.class.class.class:pseudo[attrib=what][attrib=what] OP selector

		It is all additive

		OP

		space = descendant
		>     = direct descendant
		+     = sibling (E+F Matches any F element immediately preceded by a sibling element E)

		[foo]        Foo is present as an attribute
		[foo="warning"]   Matches any E element whose "foo" attribute value is exactly equal to "warning".
		E[foo~="warning"] Matches any E element whose "foo" attribute value is a list of space-separated values, one of which is exactly equal to "warning"
		E[lang|="en"] Matches any E element whose "lang" attribute has a hyphen-separated list of values beginning (from the left) with "en".

		[item$=sdas] ends with
		[item^-sdsad] begins with

		Quotes are optional here.

		Pseudos:
			:first-child
			:last-child
			:link (same as a[href] for our purposes here)


		There can be commas separating the selector. A comma separated list result is OR'd onto the main.



		This ONLY cares about elements. text, etc, are ignored


		There should be two functions: given element, does it match the selector? and given a selector, give me all the elements

		The name `getElementsBySelector` was the original name, written back before the name `querySelector` was standardized (this library is older than you might think!), but they do the same thing..
	*/
	Element[] querySelectorAll(string selector) @safe pure {
		// FIXME: this function could probably use some performance attention
		// ... but only mildly so according to the profiler in the big scheme of things; probably negligible in a big app.


		bool caseSensitiveTags = true;
		if(parentDocument && parentDocument.loose)
			caseSensitiveTags = false;

		Element[] ret;
		foreach(sel; parseSelectorString(selector, caseSensitiveTags))
			ret ~= sel.getElements(this, null);
		return ret;
	}

	/// ditto
	alias getElementsBySelector = querySelectorAll;

	/++
		Returns child elements that have the given class name or tag name.

		Please note the standard specifies this should return a live node list. This means, in Javascript for example, if you loop over the value returned by getElementsByTagName and getElementsByClassName and remove the elements, the length of the list will decrease. When I implemented this, I figured that was more trouble than it was worth and returned a plain array instead. By the time I had the infrastructure to make it simple, I didn't want to do the breaking change.

		So these is incompatible with Javascript in the face of live dom mutation and will likely remain so.
	+/
	Element[] getElementsByClassName(string cn) @safe pure {
		// is this correct?
		return getElementsBySelector("." ~ cn);
	}

	/// ditto
	Element[] getElementsByTagName(string tag) @safe pure {
		if(parentDocument && parentDocument.loose)
			tag = tag.toLower();
		Element[] ret;
		foreach(e; tree)
			if(e.tagName == tag)
				ret ~= e;
		return ret;
	}


	/* *******************************
	          Attributes
	*********************************/

	/**
		Gets the given attribute value, or null if the
		attribute is not set.

		Note that the returned string is decoded, so it no longer contains any xml entities.
	*/
	string getAttribute(string name) const @safe pure {
		if(parentDocument && parentDocument.loose)
			name = name.toLower();
		auto e = name in attributes;
		if(e)
			return *e;
		else
			return null;
	}

	/**
		Sets an attribute. Returns this for easy chaining
	*/
	Element setAttribute(string name, string value) @safe pure {
		if(parentDocument && parentDocument.loose)
			name = name.toLower();

		// I never use this shit legitimately and neither should you
		auto it = name.toLower();
		if(it == "href" || it == "src") {
			auto v = value.strip().toLower();
			if(v.startsWith("vbscript:"))
				value = value[9..$];
			if(v.startsWith("javascript:"))
				value = value[11..$];
		}

		attributes[name] = value;

		return this;
	}

	/**
		Returns if the attribute exists.
	*/
	bool hasAttribute(string name) @safe pure {
		if(parentDocument && parentDocument.loose)
			name = name.toLower();

		if(name in attributes)
			return true;
		else
			return false;
	}

	/**
		Removes the given attribute from the element.
	*/
	Element removeAttribute(string name) @safe pure
	out(ret) {
		assert(ret is this);
	}
	do {
		if(parentDocument && parentDocument.loose)
			name = name.toLower();
		if(name in attributes)
			attributes.remove(name);

		return this;
	}

	/**
		Gets or sets the class attribute's contents. Returns
		an empty string if it has no class.
	*/
	@property string className() const @safe pure {
		auto c = getAttribute("class");
		if(c is null)
			return "";
		return c;
	}

	/// ditto
	@property Element className(string c) @safe pure {
		setAttribute("class", c);
		return this;
	}

	/*
	// this would be nice for convenience, but it broke the getter above.
	@property void opDispatch(string name)(bool boolean) if(name != "popFront") {
		if(boolean)
			setAttribute(name, name);
		else
			removeAttribute(name);
	}
	*/

	/**
		Returns the element's children.
	*/
	@property inout(Element[]) childNodes() inout @safe pure {
		return children;
	}

	private void parseAttributes(string[] whichOnes = null) @safe pure {
/+
		if(whichOnes is null)
			whichOnes = attributes.keys;
		foreach(attr; whichOnes) {
			switch(attr) {
				case "id":

				break;
				case "class":

				break;
				case "style":

				break;
				default:
					// we don't care about it
			}
		}
+/
	}


    public:


	/* *******************************
	          DOM Mutation
	*********************************/

	/// Removes all inner content from the tag; all child text and elements are gone.
	void removeAllChildren() @safe pure
		out(;this.children.length == 0)
	{
		foreach(child; children)
			child.parentNode = null;
		children = null;
	}

	/++
		Adds a sibling element before or after this one in the dom.

		History: added June 13, 2020
	+/
	Element appendSibling(Element e) @safe pure {
		parentNode.insertAfter(this, e);
		return e;
	}

	/// ditto
	Element prependSibling(Element e) @safe pure {
		parentNode.insertBefore(this, e);
		return e;
	}


    	/++
		Appends the given element to this one. If it already has a parent, it is removed from that tree and moved to this one.

		See_also: https://developer.mozilla.org/en-US/docs/Web/API/Node/appendChild

		History:
			Prior to 1 Jan 2020 (git tag v4.4.1 and below), it required that the given element must not have a parent already. This was in violation of standard, so it changed the behavior to remove it from the existing parent and instead move it here.
	+/
	Element appendChild(Element e) @safe pure
		in {
			assert(e !is null);
			assert(e !is this);
		}
		out (ret) {
			assert((e.parentNode is this), e.toString);// e.parentNode ? e.parentNode.toString : "null");
			assert(e.parentDocument is this.parentDocument);
			assert(e is ret);
		}
	do {
		if(e.parentNode !is null)
			e.parentNode.removeChild(e);

		selfClosed = false;
		if(auto frag = cast(DocumentFragment) e)
			children ~= frag.children;
		else
			children ~= e;

		e.parentNode = this;

		/+
		foreach(item; e.tree)
			item.parentDocument = this.parentDocument;
		+/

		return e;
	}

	/// Inserts the second element to this node, right before the first param
	Element insertBefore(in Element where, Element what) @safe pure
		in {
			assert(where !is null);
			assert(where.parentNode is this);
			assert(what !is null);
			assert(what.parentNode is null);
		}
		out (ret) {
			assert(where.parentNode is this);
			assert(what.parentNode is this);

			assert(what.parentDocument is this.parentDocument);
			assert(ret is what);
		}
	do {
		foreach(i, e; children) {
			if(e is where) {
				if(auto frag = cast(DocumentFragment) what) {
					children = children[0..i] ~ frag.children ~ children[i..$];
					foreach(child; frag.children)
						child.parentNode = this;
				} else {
					children = children[0..i] ~ what ~ children[i..$];
				}
				what.parentNode = this;
				return what;
			}
		}

		return what;

		assert(0);
	}

	/++
		Inserts the given element `what` as a sibling of the `this` element, after the element `where` in the parent node.
	+/
	Element insertAfter(in Element where, Element what) @safe pure
		in {
			assert(where !is null);
			assert(where.parentNode is this);
			assert(what !is null);
			assert(what.parentNode is null);
		}
		out (ret) {
			assert(where.parentNode is this);
			assert(what.parentNode is this);
			assert(what.parentDocument is this.parentDocument);
			assert(ret is what);
		}
	do {
		foreach(i, e; children) {
			if(e is where) {
				if(auto frag = cast(DocumentFragment) what) {
					children = children[0 .. i + 1] ~ what.children ~ children[i + 1 .. $];
					foreach(child; frag.children)
						child.parentNode = this;
				} else
					children = children[0 .. i + 1] ~ what ~ children[i + 1 .. $];
				what.parentNode = this;
				return what;
			}
		}

		return what;

		assert(0);
	}

	/// swaps one child for a new thing. Returns the old child which is now parentless.
	Element swapNode(Element child, Element replacement) @safe pure
		in {
			assert(child !is null);
			assert(replacement !is null);
			assert(child.parentNode is this);
		}
		out(ret) {
			assert(ret is child);
			assert(ret.parentNode is null);
			assert(replacement.parentNode is this);
			assert(replacement.parentDocument is this.parentDocument);
		}
	do {
		foreach(ref c; this.children)
			if(c is child) {
				c.parentNode = null;
				c = replacement;
				c.parentNode = this;
				return child;
			}
		assert(0);
	}


	/++
		Appends the given to the node.


		Calling `e.appendText(" hi")` on `<example>text <b>bold</b></example>`
		yields `<example>text <b>bold</b> hi</example>`.

		See_Also:
			[firstInnerText], [directText], [innerText], [appendChild]
	+/
	Element appendText(string text) @safe pure {
		Element e = new TextNode(parentDocument, text);
		appendChild(e);
		return this;
	}

	/++
		Returns child elements which are of a tag type (excludes text, comments, etc.).


		childElements of `<example>text <b>bold</b></example>` is just the `<b>` tag.

		Params:
			tagName = filter results to only the child elements with the given tag name.
	+/
	@property Element[] childElements(string tagName = null) @safe pure {
		Element[] ret;
		foreach(c; children)
			if(c.nodeType == 1 && (tagName is null || c.tagName == tagName))
				ret ~= c;
		return ret;
	}

	/++
		Appends the given html to the element, returning the elements appended


		This is similar to `element.innerHTML += "html string";` in Javascript.
	+/
	Element[] appendHtml(string html) @safe pure {
		Document d = new Document("<root>" ~ html ~ "</root>");
		return stealChildren(d.root);
	}


	/++
		Inserts a child under this element after the element `where`.
	+/
	void insertChildAfter(Element child, Element where) @safe pure
		in(child !is null)
		in(where !is null)
		in(where.parentNode is this)
		in(!selfClosed)
		//in(isInArray(where, children))
		out(;child.parentNode is this)
		out(;where.parentNode is this)
		//out(;isInArray(where, children))
		//out(;isInArray(child, children))
	{
		foreach(ref i, c; children) {
			if(c is where) {
				i++;
				if(auto frag = cast(DocumentFragment) child) {
					children = children[0..i] ~ child.children ~ children[i..$];
					//foreach(child; frag.children)
						//child.parentNode = this;
				} else
					children = children[0..i] ~ child ~ children[i..$];
				child.parentNode = this;
				break;
			}
		}
	}

	/++
		Reparents all the child elements of `e` to `this`, leaving `e` childless.

		Params:
			e = the element whose children you want to steal
			position = an existing child element in `this` before which you want the stolen children to be inserted. If `null`, it will append the stolen children at the end of our current children.
	+/
	Element[] stealChildren(Element e, Element position = null) @safe pure
		in {
			assert(!selfClosed);
			assert(e !is null);
			//if(position !is null)
				//assert(isInArray(position, children));
		}
		out (ret) {
			assert(e.children.length == 0);
		}
	do {
		foreach(c; e.children) {
			c.parentNode = this;
		}
		if(position is null)
			children ~= e.children;
		else {
			foreach(i, child; children) {
				if(child is position) {
					children = children[0..i] ~
						e.children ~
						children[i..$];
					break;
				}
			}
		}

		auto ret = e.children[];
		e.children.length = 0;

		return ret;
	}

    	/// Puts the current element first in our children list. The given element must not have a parent already.
	Element prependChild(Element e) @safe pure
		in(e.parentNode is null)
		in(!selfClosed)
		out(;e.parentNode is this)
		out(;e.parentDocument is this.parentDocument)
		out(;children[0] is e)
	{
		if(auto frag = cast(DocumentFragment) e) {
			children = e.children ~ children;
			foreach(child; frag.children)
				child.parentNode = this;
		} else
			children = e ~ children;
		e.parentNode = this;
		return e;
	}


	/**
		Returns a string containing all child elements, formatted such that it could be pasted into
		an XML file.
	*/
	@property string innerHTML(Appender!string where = appender!string()) const @safe pure {
		if(children is null)
			return "";

		auto start = where.data.length;

		foreach(child; children) {
			assert(child !is null);

			child.writeToAppender(where);
		}

		return where.data[start .. $];
	}

	/**
		Takes some html and replaces the element's children with the tree made from the string.
	*/
	@property Element innerHTML(string html, bool strict = false) @safe pure {
		if(html.length)
			selfClosed = false;

		if(html.length == 0) {
			// I often say innerHTML = ""; as a shortcut to clear it out,
			// so let's optimize that slightly.
			removeAllChildren();
			return this;
		}

		auto doc = new Document();
		doc.parseUtf8("<innerhtml>" ~ html ~ "</innerhtml>", strict, strict); // FIXME: this should preserve the strictness of the parent document

		children = doc.root.children;
		foreach(c; children) {
			c.parentNode = this;
		}

		doc.root.children = null;

		return this;
	}

	/// ditto
	@property Element innerHTML(Html html) @safe pure {
		return this.innerHTML = html.source;
	}

	/**
		Replaces this node with the given html string, which is parsed

		Note: this invalidates the this reference, since it is removed
		from the tree.

		Returns the new children that replace this.
	*/
	@property Element[] outerHTML(string html) @safe pure {
		auto doc = new Document();
		doc.parseUtf8("<innerhtml>" ~ html ~ "</innerhtml>"); // FIXME: needs to preserve the strictness

		children = doc.root.children;
		foreach(c; children) {
			c.parentNode = this;
		}

		stripOut();

		return doc.root.children;
	}

	/++
		Returns all the html for this element, including the tag itself.

		This is equivalent to calling toString().
	+/
	@property string outerHTML() @safe pure {
		return this.toString();
	}

	/// This sets the inner content of the element *without* trying to parse it.
	/// You can inject any code in there; this serves as an escape hatch from the dom.
	///
	/// The only times you might actually need it are for < style > and < script > tags in html.
	/// Other than that, innerHTML and/or innerText should do the job.
	@property void innerRawSource(string rawSource) @safe pure {
		children.length = 0;
		auto rs = new RawSource(parentDocument, rawSource);
		children ~= rs;
		rs.parentNode = this;
	}

	/++
		Replaces the element `find`, which must be a child of `this`, with the element `replace`, which must have no parent.
	+/
	Element replaceChild(Element find, Element replace) @safe pure
		in {
			assert(find !is null);
			assert(find.parentNode is this);
			assert(replace !is null);
			assert(replace.parentNode is null);
		}
		out(ret) {
			assert(ret is replace);
			assert(replace.parentNode is this);
			assert(replace.parentDocument is this.parentDocument);
			assert(find.parentNode is null);
		}
	do {
		// FIXME
		//if(auto frag = cast(DocumentFragment) replace)
			//return this.replaceChild(frag, replace.children);
		for(int i = 0; i < children.length; i++) {
			if(children[i] is find) {
				replace.parentNode = this;
				children[i].parentNode = null;
				children[i] = replace;
				return replace;
			}
		}

		throw new Exception("no such child ");// ~  find.toString ~ " among " ~ typeid(this).toString);//.toString ~ " magic \n\n\n" ~ find.parentNode.toString);
	}

	/**
		Replaces the given element with a whole group.
	*/
	void replaceChild(Element find, Element[] replace) @safe pure
		in(find !is null)
		in(replace !is null)
		in(find.parentNode is this)
		out(;find.parentNode is null)
		out(;children.length >= replace.length)
		in {
			debug foreach(r; replace)
				assert(r.parentNode is null);
		}
		out {
			debug foreach(child; children)
				assert(child !is find);
			debug foreach(r; replace)
				assert(r.parentNode is this);
		}
	do {
		if(replace.length == 0) {
			removeChild(find);
			return;
		}
		assert(replace.length);
		for(int i = 0; i < children.length; i++) {
			if(children[i] is find) {
				children[i].parentNode = null; // this element should now be dead
				children[i] = replace[0];
				foreach(e; replace) {
					e.parentNode = this;
				}

				children = .insertAfter(children, i, replace[1..$]);

				return;
			}
		}

		throw new Exception("no such child");
	}


	/**
		Removes the given child from this list.

		Returns the removed element.
	*/
	Element removeChild(Element c) @safe pure
		in(c !is null)
		in(c.parentNode is this)
		out(;c.parentNode is null)
		out {
			debug foreach(child; children)
				assert(child !is c);
		}
	do {
		foreach(i, e; children) {
			if(e is c) {
				children = children[0..i] ~ children [i+1..$];
				c.parentNode = null;
				return c;
			}
		}

		throw new Exception("no such child");
	}

	/// This removes all the children from this element, returning the old list.
	Element[] removeChildren() @safe pure
		out(;children.length == 0)
		out (ret) {
			debug foreach(r; ret)
				assert(r.parentNode is null);
		}
	do {
		Element[] oldChildren = children.dup;
		foreach(c; oldChildren)
			c.parentNode = null;

		children.length = 0;

		return oldChildren;
	}

	/**
		Fetch the inside text, with all tags stripped out.

		<p>cool <b>api</b> &amp; code dude<p>
		innerText of that is "cool api & code dude".

		This does not match what real innerText does!
		http://perfectionkills.com/the-poor-misunderstood-innerText/

		It is more like [textContent].

		See_Also:
			[visibleText], which is closer to what the real `innerText`
			does.
	*/
	@property string innerText() const @safe pure {
		string s;
		foreach(child; children) {
			if(child.nodeType != NodeType.Text)
				s ~= child.innerText;
			else
				s ~= child.nodeValue();
		}
		return s;
	}

	/// ditto
	alias textContent = innerText;

	/++
		Gets the element's visible text, similar to how it would look assuming
		the document was HTML being displayed by a browser. This means it will
		attempt whitespace normalization (unless it is a `<pre>` tag), add `\n`
		characters for `<br>` tags, and I reserve the right to make it process
		additional css and tags in the future.

		If you need specific output, use the more stable [textContent] property
		or iterate yourself with [tree] or a recursive function with [children].

		History:
			Added March 25, 2022 (dub v10.8)
	+/
	string visibleText() const @safe pure {
		return this.visibleTextHelper(this.tagName == "pre");
	}

	private string visibleTextHelper(bool pre) const @safe pure {
		string result;
		foreach(thing; this.children) {
			if(thing.nodeType == NodeType.Text)
				result ~= pre ? thing.nodeValue : normalizeWhitespace(thing.nodeValue);
			else if(thing.tagName == "br")
				result ~= "\n";
			else
				result ~= thing.visibleTextHelper(pre || thing.tagName == "pre");
		}
		return result;
	}

	/**
		Sets the inside text, replacing all children. You don't
		have to worry about entity encoding.
	*/
	@property void innerText(string text) @safe pure {
		selfClosed = false;
		Element e = new TextNode(parentDocument, text);
		children = [e];
		e.parentNode = this;
	}

	/**
		Strips this node out of the document, replacing it with the given text
	*/
	@property void outerText(string text) @safe pure {
		parentNode.replaceChild(this, new TextNode(parentDocument, text));
	}

	/**
		Same result as innerText; the tag with all inner tags stripped out
	*/
	@property string outerText() const @safe pure {
		return innerText;
	}


	/* *******************************
	          Miscellaneous
	*********************************/

	/// This is a full clone of the element. Alias for cloneNode(true) now. Don't extend it.
	@property Element cloned() @safe pure
	/+
		out(ret) {
			// FIXME: not sure why these fail...
			assert(ret.children.length == this.children.length, format("%d %d", ret.children.length, this.children.length));
			assert(ret.tagName == this.tagName);
		}
	do {
	+/
	{
		return this.cloneNode(true);
	}

	/// Clones the node. If deepClone is true, clone all inner tags too. If false, only do this tag (and its attributes), but it will have no contents.
	Element cloneNode(bool deepClone) @safe pure {
		auto e = Element.make(this.tagName);
		e.attributes = this.attributes.aadup;
		e.selfClosed = this.selfClosed;

		if(deepClone) {
			foreach(child; children) {
				e.appendChild(child.cloneNode(true));
			}
		}


		return e;
	}

	/// W3C DOM interface. Only really meaningful on [TextNode] instances, but the interface is present on the base class.
	string nodeValue() const @safe pure {
		return "";
	}

	// should return int
	///.
	@property int nodeType() const @safe pure {
		return 1;
	}


	invariant () {
		debug assert(tagName.indexOf(" ") == -1);

		// commented cuz it gets into recursive pain and eff dat.
		/+
		if(children !is null)
		foreach(child; children) {
		//	assert(parentNode !is null);
			assert(child !is null);
			assert(child.parent_.asElement is this, format("%s is not a parent of %s (it thought it was %s)", tagName, child.tagName, child.parent_.asElement is null ? "null" : child.parent_.asElement.tagName));
			assert(child !is this);
			//assert(child !is parentNode);
		}
		+/

		/+
		// this isn't helping
		if(parent_ && parent_.asElement) {
			bool found = false;
			foreach(child; parent_.asElement.children)
				if(child is this)
					found = true;
			assert(found, format("%s lists %s as parent, but it is not in children", typeid(this), typeid(this.parent_.asElement)));
		}
		+/

		/+ // only depend on parentNode's accuracy if you shuffle things around and use the top elements - where the contracts guarantee it on out
		if(parentNode !is null) {
			// if you have a parent, you should share the same parentDocument; this is appendChild()'s job
			auto lol = cast(TextNode) this;
			assert(parentDocument is parentNode.parentDocument, lol is null ? this.tagName : lol.contents);
		}
		+/
		//assert(parentDocument !is null); // no more; if it is present, we use it, but it is not required
		// reason is so you can create these without needing a reference to the document
	}

	/**
		Turns the whole element, including tag, attributes, and children, into a string which could be pasted into
		an XML file.
	*/
	override string toString() const @safe pure {
		return writeToAppender();
	}

	/++
		Returns if the node would be printed to string as `<tag />` or `<tag></tag>`. In other words, if it has no non-empty text nodes and no element nodes. Please note that whitespace text nodes are NOT considered empty; `Html("<tag> </tag>").isEmpty == false`.


		The value is undefined if there are comment or processing instruction nodes. The current implementation returns false if it sees those, assuming the nodes haven't been stripped out during parsing. But I'm not married to the current implementation and reserve the right to change it without notice.

		History:
			Added December 3, 2021 (dub v10.5)

	+/
	public bool isEmpty() const @safe pure {
		foreach(child; this.children) {
			// any non-text node is of course not empty since that's a tag
			if(child.nodeType != NodeType.Text)
				return false;
			// or a text node is empty if it is is a null or empty string, so this length check fixes that
			if(child.nodeValue.length)
				return false;
		}

		return true;
	}

	protected string toPrettyStringIndent(bool insertComments, int indentationLevel, string indentWith) const @safe pure {
		if(indentWith is null)
			return null;

		// at the top we don't have anything to really do
		//if(parent_ is null)
			//return null;

			// I've used isEmpty before but this other check seems better....
			//|| this.isEmpty())

		string s;

		if(insertComments) s ~= "<!--";
		s ~= "\n";
		foreach(indent; 0 .. indentationLevel)
			s ~= indentWith;
		if(insertComments) s ~= "-->";

		return s;
	}

	/++
		Writes out with formatting. Be warned: formatting changes the contents. Use ONLY
		for eyeball debugging.

		$(PITFALL
			This function is not stable. Its interface and output may change without
			notice. The only promise I make is that it will continue to make a best-
			effort attempt at being useful for debugging by human eyes.

			I have used it in the past for diffing html documents, but even then, it
			might change between versions. If it is useful, great, but beware; this
			use is at your own risk.
		)

		History:
			On November 19, 2021, I changed this to `final`. If you were overriding it,
			change our override to `toPrettyStringImpl` instead. It now just calls
			`toPrettyStringImpl.strip` to be an entry point for a stand-alone call.

			If you are calling it as part of another implementation, you might want to
			change that call to `toPrettyStringImpl` as well.

			I am NOT considering this a breaking change since this function is documented
			to only be used for eyeball debugging anyway, which means the exact format is
			not specified and the override behavior can generally not be relied upon.

			(And I find it extremely unlikely anyone was subclassing anyway, but if you were,
			email me, and we'll see what we can do. I'd like to know at least.)

			I reserve the right to make future changes in the future without considering
			them breaking as well.
	+/
	final string toPrettyString(bool insertComments = false, int indentationLevel = 0, string indentWith = "\t") const @safe pure {
		return toPrettyStringImpl(insertComments, indentationLevel, indentWith).strip;
	}

	string toPrettyStringImpl(bool insertComments = false, int indentationLevel = 0, string indentWith = "\t") const @trusted pure {

		// first step is to concatenate any consecutive text nodes to simplify
		// the white space analysis. this changes the tree! but i'm allowed since
		// the comment always says it changes the comments
		//
		// actually i'm not allowed cuz it is const so i will cheat and lie
		/+
		TextNode lastTextChild = null;
		for(int a = 0; a < this.children.length; a++) {
			auto child = this.children[a];
			if(auto tn = cast(TextNode) child) {
				if(lastTextChild) {
					lastTextChild.contents ~= tn.contents;
					for(int b = a; b < this.children.length - 1; b++)
						this.children[b] = this.children[b + 1];
					this.children = this.children[0 .. $-1];
				} else {
					lastTextChild = tn;
				}
			} else {
				lastTextChild = null;
			}
		}
		+/

		auto inlineElements = (parentDocument is null ? null : parentDocument.inlineElements);

		const(Element)[] children;

		TextNode lastTextChild = null;
		for(int a = 0; a < this.children.length; a++) {
			auto child = this.children[a];
			if(auto tn = cast(const(TextNode)) child) {
				if(lastTextChild !is null) {
					lastTextChild.contents ~= tn.contents;
				} else {
					lastTextChild = new TextNode("");
					lastTextChild.parentNode = cast(Element) this;
					lastTextChild.contents ~= tn.contents;
					children ~= lastTextChild;
				}
			} else {
				lastTextChild = null;
				children ~= child;
			}
		}

		string s = toPrettyStringIndent(insertComments, indentationLevel, indentWith);

		s ~= "<";
		s ~= tagName;

		// i sort these for consistent output. might be more legible
		// but especially it keeps it the same for diff purposes.
		auto keys = sort(attributes.keys);
		foreach(n; keys) {
			auto v = attributes[n];
			s ~= " ";
			s ~= n;
			s ~= "=\"";
			s ~= htmlEntitiesEncode(v);
			s ~= "\"";
		}

		if(selfClosed){
			s ~= " />";
			return s;
		}

		s ~= ">";

		// for simple `<collection><item>text</item><item>text</item></collection>`, let's
		// just keep them on the same line

		if(isEmpty) {
			// no work needed, this is empty so don't indent just for a blank line
		} else if(children.length == 1 && children[0].isEmpty) {
			// just one empty one, can put it inline too
			s ~= children[0].toString();
		} else if(tagName.isInArray(inlineElements) || allAreInlineHtml(children, inlineElements)) {
			foreach(child; children) {
				s ~= child.toString();//toPrettyString(false, 0, null);
			}
		} else {
			foreach(child; children) {
				assert(child !is null);

				s ~= child.toPrettyStringImpl(insertComments, indentationLevel + 1, indentWith);
			}

			s ~= toPrettyStringIndent(insertComments, indentationLevel, indentWith);
		}

		s ~= "</";
		s ~= tagName;
		s ~= ">";

		return s;
	}

	/+
	/// Writes out the opening tag only, if applicable.
	string writeTagOnly(Appender!string where = appender!string()) const {
	+/

	/// This is the actual implementation used by toString. You can pass it a preallocated buffer to save some time.
	/// Note: the ordering of attributes in the string is undefined.
	/// Returns the string it creates.
	string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		assert(tagName !is null);

		where.reserve((this.children.length + 1) * 512);

		auto start = where.data.length;

		where.put("<");
		where.put(tagName);

		auto keys = sort(attributes.keys);
		foreach(n; keys) {
			auto v = attributes[n]; // I am sorting these for convenience with another project. order of AAs is undefined, so I'm allowed to do it.... and it is still undefined, I might change it back later.
			//assert(v !is null);
			where.put(" ");
			where.put(n);
			where.put("=\"");
			htmlEntitiesEncode(v, where);
			where.put("\"");
		}

		if(selfClosed){
			where.put(" />");
			return where.data[start .. $];
		}

		where.put('>');

		innerHTML(where);

		where.put("</");
		where.put(tagName);
		where.put('>');

		return where.data[start .. $];
	}

	/**
		Returns a lazy range of all its children, recursively.
	*/
	@property ElementStream tree() @safe pure {
		return new ElementStream(this);
	}

	/++
		Adds a form field to this element, normally a `<input>` but `type` can also be `"textarea"`.

		This is fairly html specific and the label uses my style. I recommend you view the source before you use it to better understand what it does.
	+/
	/// Tags: HTML, HTML5
	Element addField(string label, string name, string type = "text", FormFieldOptions fieldOptions = FormFieldOptions.none) @safe pure {
		auto fs = this;
		auto i = fs.addChild("label");

		if(!(type == "checkbox" || type == "radio"))
			i.addChild("span", label);

		Element input;
		if(type == "textarea")
			input = i.addChild("textarea").
			setAttribute("name", name).
			setAttribute("rows", "6");
		else
			input = i.addChild("input").
			setAttribute("name", name).
			setAttribute("type", type);

		if(type == "checkbox" || type == "radio")
			i.addChild("span", label);

		// these are html 5 attributes; you'll have to implement fallbacks elsewhere. In Javascript or maybe I'll add a magic thing to html.d later.
		fieldOptions.applyToElement(input);
		return i;
	}

	/// ditto
	Element addField(Element label, string name, string type = "text", FormFieldOptions fieldOptions = FormFieldOptions.none) @safe pure {
		auto fs = this;
		auto i = fs.addChild("label");
		i.addChild(label);
		Element input;
		if(type == "textarea")
			input = i.addChild("textarea").
			setAttribute("name", name).
			setAttribute("rows", "6");
		else
			input = i.addChild("input").
			setAttribute("name", name).
			setAttribute("type", type);

		// these are html 5 attributes; you'll have to implement fallbacks elsewhere. In Javascript or maybe I'll add a magic thing to html.d later.
		fieldOptions.applyToElement(input);
		return i;
	}

	/// ditto
	Element addField(string label, string name, FormFieldOptions fieldOptions) @safe pure {
		return addField(label, name, "text", fieldOptions);
	}

	/// ditto
	Element addField(string label, string name, string[string] options, FormFieldOptions fieldOptions = FormFieldOptions.none) @safe pure {
		auto fs = this;
		auto i = fs.addChild("label");
		i.addChild("span", label);
		auto sel = i.addChild("select").setAttribute("name", name);

		foreach(k, opt; options)
			sel.addChild("option", opt, k);

		// FIXME: implement requirements somehow

		return i;
	}

	/// ditto
	Element addSubmitButton(string label = null) @safe pure {
		auto t = this;
		auto holder = t.addChild("div");
		holder.addClass("submit-holder");
		auto i = holder.addChild("input");
		i.setAttribute("type", "submit");
		if(label.length)
			i.setAttribute("value", label);
		return holder;
	}

}

//pragma(msg, __traits(classInstanceSize, Element));
//pragma(msg, Element.tupleof);

// FIXME: since Document loosens the input requirements, it should probably be the sub class...
/++
	Specializes Document for handling generic XML. (always uses strict mode, uses xml mime type and file header)

	History:
		On December 16, 2022, it disabled the special case treatment of `<script>` and `<style>` that [Document]
		does for HTML. To get the old behavior back, add `, true` to your constructor call.
+/
/// Group: core_functionality
class XmlDocument : Document {
	this(string data, bool enableHtmlHacks = false) @safe pure {
		selfClosedElements = null;
		inlineElements = null;
		rawSourceElements = null;
		contentType = "text/xml; charset=utf-8";
		_prolog = `<?xml version="1.0" encoding="UTF-8"?>` ~ "\n";

		parseStrict(data, !enableHtmlHacks);
	}
}

@safe pure unittest {
	// FIXME: i should also make XmlDocument do different entities than just html too.
	auto str = "<html><style>foo {}</style><script>void function() { a < b; }</script></html>";
	auto document = new Document(str, true, true);
	assert(document.requireSelector("style").children[0].tagName == "#raw");
	assert(document.requireSelector("script").children[0].tagName == "#raw");
	assertThrown(new XmlDocument(str));
}


/* domconvenience follows { */

/// finds comments that match the given txt. Case insensitive, strips whitespace.
/// Group: core_functionality
Element[] findComments(Document document, string txt) @safe pure {
	return findComments(document.root, txt);
}

/// ditto
Element[] findComments(Element element, string txt) @safe pure {
	txt = txt.strip().toLower();
	Element[] ret;

	foreach(comment; element.getElementsByTagName("#comment")) {
		string t = comment.nodeValue().strip().toLower();
		if(t == txt)
			ret ~= comment;
	}

	return ret;
}

/// An option type that propagates null. See: [Element.optionSelector]
/// Group: implementations
struct MaybeNullElement(SomeElementType) {
	this(SomeElementType ele) {
		this.element = ele;
	}
	SomeElementType element;

	/// Forwards to the element, wit a null check inserted that propagates null.
	auto opDispatch(string method, T...)(T args) {
		alias type = typeof(__traits(getMember, element, method)(args));
		static if(is(type : Element)) {
			if(element is null)
				return MaybeNullElement!type(null);
			return __traits(getMember, element, method)(args);
		} else static if(is(type == string)) {
			if(element is null)
				return cast(string) null;
			return __traits(getMember, element, method)(args);
		} else static if(is(type == void)) {
			if(element is null)
				return;
			__traits(getMember, element, method)(args);
		} else {
			static assert(0);
		}
	}

	/// Allows implicit casting to the wrapped element.
	alias element this;
}

/++
	A collection of elements which forwards methods to the children.
+/
/// Group: implementations
struct ElementCollection {
	///
	this(Element e) @safe pure {
		elements = [e];
	}

	///
	this(Element e, string selector) @safe pure {
		elements = e.querySelectorAll(selector);
	}

	///
	this(Element[] e) @safe pure {
		elements = e;
	}

	Element[] elements;
	//alias elements this; // let it implicitly convert to the underlying array

	///
	ElementCollection opIndex(string selector) @safe pure {
		ElementCollection ec;
		foreach(e; elements)
			ec.elements ~= e.getElementsBySelector(selector);
		return ec;
	}

	///
	Element opIndex(int i) @safe pure {
		return elements[i];
	}

	/// if you slice it, give the underlying array for easy forwarding of the
	/// collection to range expecting algorithms or looping over.
	Element[] opSlice() @safe pure {
		return elements;
	}

	/// And input range primitives so we can foreach over this
	void popFront() @safe pure {
		elements = elements[1..$];
	}

	/// ditto
	Element front() @safe pure {
		return elements[0];
	}

	/// ditto
	bool empty() @safe pure {
		return !elements.length;
	}

	/++
		Collects strings from the collection, concatenating them together
		Kinda like running reduce and ~= on it.

		---
		document["p"].collect!"innerText";
		---
	+/
	string collect(string method)(string separator = "") {
		string text;
		foreach(e; elements) {
			text ~= mixin("e." ~ method);
			text ~= separator;
		}
		return text;
	}

	/// Forward method calls to each individual [Element|element] of the collection
	/// returns this so it can be chained.
	ElementCollection opDispatch(string name, T...)(T t) {
		foreach(e; elements) {
			mixin("e." ~ name)(t);
		}
		return this;
	}

	/++
		Calls [Element.wrapIn] on each member of the collection, but clones the argument `what` for each one.
	+/
	ElementCollection wrapIn(Element what) @safe pure {
		foreach(e; elements) {
			e.wrapIn(what.cloneNode(false));
		}

		return this;
	}

	/// Concatenates two ElementCollection together.
	ElementCollection opBinary(string op : "~")(ElementCollection rhs) {
		return ElementCollection(this.elements ~ rhs.elements);
	}
}

/// Converts a camel cased propertyName to a css style dashed property-name
string unCamelCase(string a) @safe pure {
	string ret;
	foreach(c; a)
		if((c >= 'A' && c <= 'Z'))
			ret ~= "-" ~ toLower("" ~ c)[0];
		else
			ret ~= c;
	return ret;
}

/// Translates a css style property-name to a camel cased propertyName
string camelCase(string a) @safe pure {
	string ret;
	bool justSawDash = false;
	foreach(c; a)
		if(c == '-') {
			justSawDash = true;
		} else {
			if(justSawDash) {
				justSawDash = false;
				ret ~= toUpper("" ~ c);
			} else
				ret ~= c;
		}
	return ret;
}









// domconvenience ends }











// NOTE: do *NOT* override toString on Element subclasses. It won't work.
// Instead, override writeToAppender();

// FIXME: should I keep processing instructions like <?blah ?> and <!-- blah --> (comments too lol)? I *want* them stripped out of most my output, but I want to be able to parse and create them too.

// Stripping them is useful for reading php as html.... but adding them
// is good for building php.

// I need to maintain compatibility with the way it is now too.

// tag soup works for most the crap I know now! If you have two bad closing tags back to back, it might erase one, but meh
// that's rarer than the flipped closing tags that hack fixes so I'm ok with it. (Odds are it should be erased anyway; it's
// most likely a typo so I say kill kill kill.


///.
/// Group: bonus_functionality
enum NodeType { Text = 3 }


/// You can use this to do an easy null check or a dynamic cast+null check on any element.
/// Group: core_functionality
T require(T = Element, string file = __FILE__, int line = __LINE__)(Element e) if(is(T : Element))
	in {}
	out(ret) { assert(ret !is null); }
do {
	auto ret = cast(T) e;
	if(ret is null)
		throw new ElementNotFoundException(T.stringof, "passed value", e, file, line);
	return ret;
}


///.
/// Group: core_functionality
class DocumentFragment : Element {
	///.
	this(Document _parentDocument) @safe pure {
		tagName = "#fragment";
		super(_parentDocument);
	}

	/++
		Creates a document fragment from the given HTML. Note that the HTML is assumed to close all tags contained inside it.

		Since: March 29, 2018 (or git tagged v2.1.0)
	+/
	this(Html html) @safe pure {
		this(null);

		this.innerHTML = html.source;
	}

	///.
	override string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		return this.innerHTML(where);
	}

	override string toPrettyStringImpl(bool insertComments, int indentationLevel, string indentWith) const @safe pure {
		string s;
		foreach(child; children)
			s ~= child.toPrettyStringImpl(insertComments, indentationLevel, indentWith);
		return s;
	}

	/// DocumentFragments don't really exist in a dom, so they ignore themselves in parent nodes
	/*
	override inout(Element) parentNode() inout {
		return children.length ? children[0].parentNode : null;
	}
	*/
	/+
	override Element parentNode(Element p) {
		this.parentNode = p;
		foreach(child; children)
			child.parentNode = p;
		return p;
	}
	+/
}

@safe pure unittest {
	with(new DocumentFragment(Html(""))) {
		assert(!childNodes.length);
		assert(!parentNode);
		assert(toString() == "");
	}
	with(new DocumentFragment(Html("<b></b>"))) {
		assert(childNodes.length == 1);
	}
	with(new DocumentFragment(Html("<img><b></b>"))) {
		assert(childNodes.length == 2);
		assert(childNodes[0].nextSibling);
		assert(childNodes[0].nextSibling.tagName == "b");
	}
}

/// Given text, encode all html entities on it - &, <, >, and ". This function also
/// encodes all 8 bit characters as entities, thus ensuring the resultant text will work
/// even if your charset isn't set right. You can suppress with by setting encodeNonAscii = false
///
/// The output parameter can be given to append to an existing buffer. You don't have to
/// pass one; regardless, the return value will be usable for you, with just the data encoded.
/// Group: core_functionality
string htmlEntitiesEncode(string data, Appender!string output = appender!string(), bool encodeNonAscii = true) @safe pure {
	// if there's no entities, we can save a lot of time by not bothering with the
	// decoding loop. This check cuts the net toString time by better than half in my test.
	// let me know if it made your tests worse though, since if you use an entity in just about
	// every location, the check will add time... but I suspect the average experience is like mine
	// since the check gives up as soon as it can anyway.

	bool shortcut = true;
	foreach(char c; data) {
		// non ascii chars are always higher than 127 in utf8; we'd better go to the full decoder if we see it.
		if(c == '<' || c == '>' || c == '"' || c == '&' || (encodeNonAscii && cast(uint) c > 127)) {
			shortcut = false; // there's actual work to be done
			break;
		}
	}

	if(shortcut) {
		output.put(data);
		return data;
	}

	auto start = output.data.length;

	output.reserve(data.length + 64); // grab some extra space for the encoded entities

	foreach(dchar d; data) {
		if(d == '&')
			output.put("&amp;");
		else if (d == '<')
			output.put("&lt;");
		else if (d == '>')
			output.put("&gt;");
		else if (d == '\"')
			output.put("&quot;");
//		else if (d == '\'')
//			output.put("&#39;"); // if you are in an attribute, it might be important to encode for the same reason as double quotes
			// FIXME: should I encode apostrophes too? as &#39;... I could also do space but if your html is so bad that it doesn't
			// quote attributes at all, maybe you deserve the xss. Encoding spaces will make everything really ugly so meh
			// idk about apostrophes though. Might be worth it, might not.
		else if (!encodeNonAscii || (d < 128 && d > 0))
			output.put(d);
		else
			output.put("&#" ~ std.conv.to!string(cast(int) d) ~ ";");
	}

	//assert(output !is null); // this fails on empty attributes.....
	return output.data[start .. $];

//	data = data.replace("\u00a0", "&nbsp;");
}

/// An alias for htmlEntitiesEncode; it works for xml too
/// Group: core_functionality
string xmlEntitiesEncode(string data) @safe pure {
	return htmlEntitiesEncode(data);
}

/// This helper function is used for decoding html entities. It has a hard-coded list of entities and characters.
/// Group: core_functionality
dchar parseEntity(in char[] entity) @safe pure {

	char[128] buffer;
	int bpos;
	foreach(char c; entity[1 .. $-1])
		buffer[bpos++] = c;
	char[] entityAsString = buffer[0 .. bpos];

	if (auto foundEntity = entityAsString in availableEntities) {
		return *foundEntity;
	}

	switch(entity[1..$-1]) {
		case "quot":
			return '"';
		case "apos":
			return '\'';
		case "lt":
			return '<';
		case "gt":
			return '>';
		case "amp":
			return '&';
		// the next are html rather than xml

		// and handling numeric entities
		default:
			if(entity[1] == '#') {
				if(entity[2] == 'x' /*|| (!strict && entity[2] == 'X')*/) {
					auto hex = entity[3..$-1];

					auto p = intFromHex(to!string(hex).toLower());
					return cast(dchar) p;
				} else {
					auto decimal = entity[2..$-1];

					// dealing with broken html entities
					while(decimal.length && (decimal[0] < '0' || decimal[0] >   '9'))
						decimal = decimal[1 .. $];

					while(decimal.length && (decimal[$-1] < '0' || decimal[$-1] >   '9'))
						decimal = decimal[0 .. $ - 1];

					if(decimal.length == 0)
						return ' '; // this is really broken html
					// done with dealing with broken stuff

					auto p = std.conv.to!int(decimal);
					return cast(dchar) p;
				}
			} else
				return '\ufffd'; // replacement character diamond thing
	}

	assert(0);
}

@safe pure unittest {
	// not in the binary search
	assert(parseEntity("&quot;") == '"');

	// numeric value
	assert(parseEntity("&#x0534;") == '\u0534');

	// not found at all
	assert(parseEntity("&asdasdasd;") == '\ufffd');

	// random values in the bin search
	assert(parseEntity("&Tab;") == '\t');
	assert(parseEntity("&raquo;") == '\&raquo;');

	// near the middle and edges of the bin search
	assert(parseEntity("&ascr;") == '\U0001d4b6');
	assert(parseEntity("&ast;") == '\u002a');
	assert(parseEntity("&Acirc;") == '\u00c2');
	assert(parseEntity("&AElig;") == '\u00c6');
	assert(parseEntity("&zwnj;") == '\u200c');
	assert(parseEntity("&InvisibleComma;") == '\u2063');

	assert(parseEntity("&CounterClockwiseContourIntegral;") == '\u2233');
}


/// This takes a string of raw HTML and decodes the entities into a nice D utf-8 string.
/// By default, it uses loose mode - it will try to return a useful string from garbage input too.
/// Set the second parameter to true if you'd prefer it to strictly throw exceptions on garbage input.
/// Group: core_functionality
string htmlEntitiesDecode(string data, bool strict = false) @safe pure {
	// this check makes a *big* difference; about a 50% improvement of parse speed on my test.
	if(data.indexOf("&") == -1) // all html entities begin with &
		return data; // if there are no entities in here, we can return the original slice and save some time

	string a; // this seems to do a *better* job than appender!

	char[4] buffer;

	bool tryingEntity = false;
	bool tryingNumericEntity = false;
	bool tryingHexEntity = false;
	string entityBeingTried;
	size_t entityStartIndex;
	int entityAttemptIndex = 0;

	foreach(idx, char ch; data) {
		if(tryingEntity) {
			entityAttemptIndex++;
			entityBeingTried = data[entityStartIndex .. idx + 1];

			if(entityBeingTried.length == 2 && ch == '#') {
				tryingNumericEntity = true;
				continue;
			} else if(tryingNumericEntity && entityBeingTried.length == 3 && ch == 'x') {
				tryingHexEntity = true;
				continue;
			}

			if(ch == '&') {
				if(strict)
					throw new Exception("unterminated entity; & inside another at " ~ entityBeingTried);

				// if not strict, let's try to parse both.

				if(entityBeingTried == "&&") {
					a ~= "&"; // double amp means keep the first one, still try to parse the next one
				} else {
					auto ch2 = parseEntity(entityBeingTried);
					if(ch2 == '\ufffd') { // either someone put this in intentionally (lol) or we failed to get it
						// but either way, just abort and keep the plain text
						foreach(char c; entityBeingTried[0 .. $ - 1]) // cut off the & we're on now
							a ~= c;
					} else {
						a ~= buffer[0.. std.utf.encode(buffer, ch2)];
					}
				}

				// tryingEntity is still true
				goto new_entity;
			} else
			if(ch == ';') {
				tryingEntity = false;
				a ~= buffer[0.. std.utf.encode(buffer, parseEntity(entityBeingTried))];
			} else if(ch == ' ') {
				// e.g. you &amp i
				if(strict)
					throw new Exception("unterminated entity at " ~ entityBeingTried);
				else {
					tryingEntity = false;
					a ~= entityBeingTried[0 .. $ - 1];
					a ~= buffer[0 .. std.utf.encode(buffer, ch)];
				}
			} else {
				if(tryingNumericEntity) {
					if(ch < '0' || ch > '9') {
						if(tryingHexEntity) {
							if(ch < 'A')
								goto trouble;
							if(ch > 'Z' && ch < 'a')
								goto trouble;
							if(ch > 'z')
								goto trouble;
						} else {
							trouble:
							if(strict)
								throw new Exception("unterminated entity at " ~ entityBeingTried);
							tryingEntity = false;
							a ~= buffer[0.. std.utf.encode(buffer, parseEntity(entityBeingTried))];
							a ~= ch;
							continue;
						}
					}
				}


				if(entityAttemptIndex >= 9) {
					done:
					if(strict)
						throw new Exception("unterminated entity at " ~ entityBeingTried);
					else {
						tryingEntity = false;
						a ~= entityBeingTried;
					}
				}
			}
		} else {
			if(ch == '&') {
				new_entity:
				tryingEntity = true;
				tryingNumericEntity = false;
				tryingHexEntity = false;
				entityStartIndex = idx;
				entityBeingTried = data[idx .. idx + 1];
				entityAttemptIndex = 0;
			} else {
				a ~= buffer[0 .. std.utf.encode(buffer, ch)];
			}
		}
	}

	if(tryingEntity) {
		if(strict)
			throw new Exception("unterminated entity at " ~ entityBeingTried);

		// otherwise, let's try to recover, at least so we don't drop any data
		a ~= entityBeingTried;
		// FIXME: what if we have "cool &amp"? should we try to parse it?
	}

	return a; // assumeUnique is actually kinda slow, lol
}

@safe pure unittest {
	// error recovery
	assert(htmlEntitiesDecode("&lt;&foo") == "<&foo"); // unterminated turned back to thing
	assert(htmlEntitiesDecode("&lt&foo") == "<&foo"); // semi-terminated... parse and carry on (is this really sane?)
	assert(htmlEntitiesDecode("loc&#61en_us&tracknum&#61;111") == "loc=en_us&tracknum=111"); // a bit of both, seen in a real life email
	assert(htmlEntitiesDecode("&amp test") == "&amp test"); // unterminated, just abort

	// in strict mode all of these should fail
	assertThrown(htmlEntitiesDecode("&lt;&foo", true));
	assertThrown(htmlEntitiesDecode("&lt&foo", true));
	assertThrown(htmlEntitiesDecode("loc&#61en_us&tracknum&#61;111", true));
	assertThrown(htmlEntitiesDecode("&amp test", true));

	// correct cases that should pass the same in strict or loose mode
	foreach(strict; [false, true]) {
		assert(htmlEntitiesDecode("&amp;hello&raquo; win", strict) == "&hello\&raquo; win");
	}
}

/// Group: implementations
abstract class SpecialElement : Element {
	this(Document _parentDocument) @safe pure {
		super(_parentDocument);
	}

	///.
	override Element appendChild(Element e) @safe pure {
		assert(0, "Cannot append to a special node");
	}

	///.
	@property override int nodeType() const @safe pure {
		return 100;
	}
}

///.
/// Group: implementations
class RawSource : SpecialElement {
	///.
	this(Document _parentDocument, string s) @safe pure {
		super(_parentDocument);
		source = s;
		tagName = "#raw";
	}

	///.
	override string nodeValue() const @safe pure {
		return this.toString();
	}

	///.
	override string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		where.put(source);
		return source;
	}

	override string toPrettyStringImpl(bool, int, string) const @safe pure {
		return source;
	}


	override RawSource cloneNode(bool deep) @safe pure {
		return new RawSource(parentDocument, source);
	}

	///.
	string source;
}

/// Group: implementations
abstract class ServerSideCode : SpecialElement {
	this(Document _parentDocument, string type) @safe pure {
		super(_parentDocument);
		tagName = "#" ~ type;
	}

	///.
	override string nodeValue() const @safe pure {
		return this.source;
	}

	///.
	override string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		auto start = where.data.length;
		where.put("<");
		where.put(source);
		where.put(">");
		return where.data[start .. $];
	}

	override string toPrettyStringImpl(bool, int, string) const @safe pure {
		return "<" ~ source ~ ">";
	}

	///.
	string source;
}

///.
/// Group: implementations
class PhpCode : ServerSideCode {
	///.
	this(Document _parentDocument, string s) @safe pure {
		super(_parentDocument, "php");
		source = s;
	}

	override PhpCode cloneNode(bool deep) @safe pure {
		return new PhpCode(parentDocument, source);
	}
}

///.
/// Group: implementations
class AspCode : ServerSideCode {
	///.
	this(Document _parentDocument, string s) @safe pure {
		super(_parentDocument, "asp");
		source = s;
	}

	override AspCode cloneNode(bool deep) @safe pure {
		return new AspCode(parentDocument, source);
	}
}

///.
/// Group: implementations
class BangInstruction : SpecialElement {
	///.
	this(Document _parentDocument, string s) @safe pure {
		super(_parentDocument);
		source = s;
		tagName = "#bpi";
	}

	///.
	override string nodeValue() const @safe pure {
		return this.source;
	}

	override BangInstruction cloneNode(bool deep) @safe pure {
		return new BangInstruction(parentDocument, source);
	}

	///.
	override string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		auto start = where.data.length;
		where.put("<!");
		where.put(source);
		where.put(">");
		return where.data[start .. $];
	}

	override string toPrettyStringImpl(bool, int, string) const @safe pure {
		string s;
		s ~= "<!";
		s ~= source;
		s ~= ">";
		return s;
	}

	///.
	string source;
}

///.
/// Group: implementations
class QuestionInstruction : SpecialElement {
	///.
	this(Document _parentDocument, string s) @safe pure {
		super(_parentDocument);
		source = s;
		tagName = "#qpi";
	}

	override QuestionInstruction cloneNode(bool deep) @safe pure {
		return new QuestionInstruction(parentDocument, source);
	}

	///.
	override string nodeValue() const @safe pure {
		return this.source;
	}

	///.
	override string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		auto start = where.data.length;
		where.put("<");
		where.put(source);
		where.put(">");
		return where.data[start .. $];
	}

	override string toPrettyStringImpl(bool, int, string) const @safe pure {
		string s;
		s ~= "<";
		s ~= source;
		s ~= ">";
		return s;
	}


	///.
	string source;
}

///.
/// Group: implementations
class HtmlComment : SpecialElement {
	///.
	this(Document _parentDocument, string s) @safe pure {
		super(_parentDocument);
		source = s;
		tagName = "#comment";
	}

	override HtmlComment cloneNode(bool deep) @safe pure {
		return new HtmlComment(parentDocument, source);
	}

	///.
	override string nodeValue() const @safe pure {
		return this.source;
	}

	///.
	override string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		auto start = where.data.length;
		where.put("<!--");
		where.put(source);
		where.put("-->");
		return where.data[start .. $];
	}

	override string toPrettyStringImpl(bool, int, string) const @safe pure {
		string s;
		s ~= "<!--";
		s ~= source;
		s ~= "-->";
		return s;
	}


	///.
	string source;
}




///.
/// Group: implementations
class TextNode : Element {
  public:
	///.
	this(Document _parentDocument, string e) @safe pure {
		super(_parentDocument);
		contents = e;
		tagName = "#text";
	}

	///
	this(string e) @safe pure {
		this(null, e);
	}

	string opDispatch(string name)(string v = null) if(0) { return null; } // text nodes don't have attributes

	///.
	static TextNode fromUndecodedString(Document _parentDocument, string html) @safe pure {
		auto e = new TextNode(_parentDocument, "");
		e.contents = htmlEntitiesDecode(html, _parentDocument is null ? false : !_parentDocument.loose);
		return e;
	}

	///.
	override @property TextNode cloneNode(bool deep) @safe pure {
		auto n = new TextNode(parentDocument, contents);
		return n;
	}

	///.
	override string nodeValue() const @safe pure {
		return this.contents; //toString();
	}

	///.
	@property override int nodeType() const @safe pure {
		return NodeType.Text;
	}

	///.
	override string writeToAppender(Appender!string where = appender!string()) const @safe pure {
		string s;
		if(contents.length)
			s = htmlEntitiesEncode(contents, where);
		else
			s = "";

		assert(s !is null);
		return s;
	}

	override string toPrettyStringImpl(bool insertComments = false, int indentationLevel = 0, string indentWith = "\t") const @safe pure {
		string s;

		string contents = this.contents;
		// we will first collapse the whitespace per html
		// sort of. note this can break stuff yo!!!!
		if(this.parentNode is null || this.parentNode.tagName != "pre") {
			string n = "";
			bool lastWasWhitespace = indentationLevel > 0;
			foreach(char c; contents) {
				if(c.isSimpleWhite) {
					if(!lastWasWhitespace)
						n ~= ' ';
					lastWasWhitespace = true;
				} else {
					n ~= c;
					lastWasWhitespace = false;
				}
			}

			contents = n;
		}

		if(this.parentNode !is null && this.parentNode.tagName != "p") {
			contents = contents.strip;
		}

		auto e = htmlEntitiesEncode(contents);
		bool first = true;
		foreach(line; splitter(e, "\n")) {
			if(first) {
				s ~= toPrettyStringIndent(insertComments, indentationLevel, indentWith);
				first = false;
			} else {
				s ~= "\n";
				if(insertComments)
					s ~= "<!--";
				foreach(i; 0 .. indentationLevel)
					s ~= "\t";
				if(insertComments)
					s ~= "-->";
			}
			s ~= line.stripRight;
		}
		return s;
	}

	///.
	override Element appendChild(Element e) @safe pure {
		assert(0, "Cannot append to a text node");
	}

	///.
	string contents;
	// alias contents content; // I just mistype this a lot,
}

/**
	There are subclasses of Element offering improved helper
	functions for the element in HTML.
*/

/++
	Represents a HTML link. This provides some convenience methods for manipulating query strings, but otherwise is sthe same Element interface.

	Please note this object may not be used for all `<a>` tags.
+/
/// Group: implementations
class Link : Element {

	/++
		Constructs `<a href="that href">that text</a>`.
	+/
	this(string href, string text) @safe pure {
		super("a");
		setAttribute("href", href);
		innerText = text;
	}

	/// ditto
	this(Document _parentDocument) @safe pure {
		super(_parentDocument);
		this.tagName = "a";
	}

/+
	/// Returns everything in the href EXCEPT the query string
	@property string targetSansQuery() {

	}

	///.
	@property string domainName() {

	}

	///.
	@property string path
+/
	/// This gets a variable from the URL's query string.
	string getValue(string name) @safe pure {
		auto vars = variablesHash();
		if(name in vars)
			return vars[name];
		return null;
	}

	private string[string] variablesHash() @safe pure {
		string href = getAttribute("href");
		if(href is null)
			return null;

		auto ques = href.indexOf("?");
		string str = "";
		if(ques != -1) {
			str = href[ques+1..$];

			auto fragment = str.indexOf("#");
			if(fragment != -1)
				str = str[0..fragment];
		}

		string[] variables = str.split("&");

		string[string] hash;

		foreach(var; variables) {
			auto index = var.indexOf("=");
			if(index == -1)
				hash[var] = "";
			else {
				hash[decodeComponent(var[0..index])] = decodeComponent(var[index + 1 .. $]);
			}
		}

		return hash;
	}

	/// Replaces all the stuff after a ? in the link at once with the given assoc array values.
	/*private*/ void updateQueryString(string[string] vars) @safe pure {
		string href = getAttribute("href");

		auto question = href.indexOf("?");
		if(question != -1)
			href = href[0..question];

		string frag = "";
		auto fragment = href.indexOf("#");
		if(fragment != -1) {
			frag = href[fragment..$];
			href = href[0..fragment];
		}

		string query = "?";
		bool first = true;
		foreach(name, value; vars) {
			if(!first)
				query ~= "&";
			else
				first = false;

			query ~= encodeComponent(name);
			if(value.length)
				query ~= "=" ~ encodeComponent(value);
		}

		if(query != "?")
			href ~= query;

		href ~= frag;

		setAttribute("href", href);
	}

	/// Sets or adds the variable with the given name to the given value
	/// It automatically URI encodes the values and takes care of the ? and &.
	override void setValue(string name, string variable) @safe pure {
		auto vars = variablesHash();
		vars[name] = variable;

		updateQueryString(vars);
	}

	/// Removes the given variable from the query string
	void removeValue(string name) @safe pure {
		auto vars = variablesHash();
		vars.remove(name);

		updateQueryString(vars);
	}

	/*
	///.
	override string toString() {

	}

	///.
	override string getAttribute(string name) {
		if(name == "href") {

		} else
			return super.getAttribute(name);
	}
	*/
}

/++
	Represents a HTML form. This slightly specializes Element to add a few more convenience methods for adding and extracting form data.

	Please note this object may not be used for all `<form>` tags.
+/
/// Group: implementations
class Form : Element {

	///.
	this(Document _parentDocument) @safe pure {
		super(_parentDocument);
		tagName = "form";
	}

	/// Overrides of the base class implementations that more confirm to *my* conventions when writing form html.
	override Element addField(string label, string name, string type = "text", FormFieldOptions fieldOptions = FormFieldOptions.none) @safe pure {
		auto t = this.querySelector("fieldset div");
		if(t is null)
			return super.addField(label, name, type, fieldOptions);
		else
			return t.addField(label, name, type, fieldOptions);
	}

	/// ditto
	override Element addField(string label, string name, FormFieldOptions fieldOptions) @safe pure {
		auto type = "text";
		auto t = this.querySelector("fieldset div");
		if(t is null)
			return super.addField(label, name, type, fieldOptions);
		else
			return t.addField(label, name, type, fieldOptions);
	}

	/// ditto
	override Element addField(string label, string name, string[string] options, FormFieldOptions fieldOptions = FormFieldOptions.none) @safe pure {
		auto t = this.querySelector("fieldset div");
		if(t is null)
			return super.addField(label, name, options, fieldOptions);
		else
			return t.addField(label, name, options, fieldOptions);
	}

	/// ditto
	override void setValue(string field, string value) @safe pure {
		setValue(field, value, true);
	}

	// FIXME: doesn't handle arrays; multiple fields can have the same name

	/// Set's the form field's value. For input boxes, this sets the value attribute. For
	/// textareas, it sets the innerText. For radio boxes and select boxes, it removes
	/// the checked/selected attribute from all, and adds it to the one matching the value.
	/// For checkboxes, if the value is non-null and not empty, it checks the box.

	/// If you set a value that doesn't exist, it throws an exception if makeNew is false.
	/// Otherwise, it makes a new input with type=hidden to keep the value.
	void setValue(string field, string value, bool makeNew) @safe pure {
		auto eles = getField(field);
		if(eles.length == 0) {
			if(makeNew) {
				addInput(field, value);
				return;
			} else
				throw new Exception("form field does not exist");
		}

		if(eles.length == 1) {
			auto e = eles[0];
			switch(e.tagName) {
				default: assert(0);
				case "textarea":
					e.innerText = value;
				break;
				case "input":
					string type = e.getAttribute("type");
					if(type is null) {
						e.setAttribute("value", value);
						return;
					}
					switch(type) {
						case "checkbox":
						case "radio":
							if(value.length && value != "false")
								e.setAttribute("checked", "checked");
							else
								e.removeAttribute("checked");
						break;
						default:
							e.setAttribute("value", value);
							return;
					}
				break;
				case "select":
					bool found = false;
					foreach(child; e.tree) {
						if(child.tagName != "option")
							continue;
						string val = child.getAttribute("value");
						if(val is null)
							val = child.innerText;
						if(val == value) {
							child.setAttribute("selected", "selected");
							found = true;
						} else
							child.removeAttribute("selected");
					}

					if(!found) {
						e.addChild("option", value)
						.setAttribute("selected", "selected");
					}
				break;
			}
		} else {
			// assume radio boxes
			foreach(e; eles) {
				string val = e.getAttribute("value");
				//if(val is null)
				//	throw new Exception("don't know what to do with radio boxes with null value");
				if(val == value)
					e.setAttribute("checked", "checked");
				else
					e.removeAttribute("checked");
			}
		}
	}

	/// This takes an array of strings and adds hidden <input> elements for each one of them. Unlike setValue,
	/// it makes no attempt to find and modify existing elements in the form to the new values.
	void addValueArray(string key, string[] arrayOfValues) @safe pure {
		foreach(arr; arrayOfValues)
			addChild("input", key, arr);
	}

	/// Gets the value of the field; what would be given if it submitted right now. (so
	/// it handles select boxes and radio buttons too). For checkboxes, if a value isn't
	/// given, but it is checked, it returns "checked", since null and "" are indistinguishable
	string getValue(string field) @safe pure {
		auto eles = getField(field);
		if(eles.length == 0)
			return "";
		if(eles.length == 1) {
			auto e = eles[0];
			switch(e.tagName) {
				default: assert(0);
				case "input":
					if(e.getAttribute("type") == "checkbox") {
						if(e.getAttribute("checked"))
							return e.getAttribute("value").length ? e.getAttribute("value") : "checked";
						return "";
					} else
						return e.getAttribute("value");
				case "textarea":
					return e.innerText;
				case "select":
					foreach(child; e.tree) {
						if(child.tagName != "option")
							continue;
						if(child.getAttribute("selected"))
							return child.getAttribute("value");
					}
				break;
			}
		} else {
			// assuming radio
			foreach(e; eles) {
				if(e.getAttribute("checked"))
					return e.getAttribute("value");
			}
		}

		return "";
	}

	// FIXME: doesn't handle multiple elements with the same name (except radio buttons)
	/++
		Returns the form's contents in application/x-www-form-urlencoded format.

		Bugs:
			Doesn't handle repeated elements of the same name nor files.
	+/
	string getPostableData() @safe pure {
		bool[string] namesDone;

		string ret;
		bool outputted = false;

		foreach(e; getElementsBySelector("[name]")) {
			if(e.getAttribute("name") in namesDone)
				continue;

			if(outputted)
				ret ~= "&";
			else
				outputted = true;

			ret ~= std.uri.encodeComponent(e.getAttribute("name")) ~ "=" ~ std.uri.encodeComponent(getValue(e.getAttribute("name")));

			namesDone[e.getAttribute("name")] = true;
		}

		return ret;
	}

	/// Gets the actual elements with the given name
	Element[] getField(string name) @safe pure {
		Element[] ret;
		foreach(e; tree) {
			if(e.getAttribute("name") == name)
				ret ~= e;
		}
		return ret;
	}

	/// Grabs the <label> with the given for tag, if there is one.
	Element getLabel(string forId) @safe pure {
		foreach(e; tree)
			if(e.tagName == "label" && e.getAttribute("for") == forId)
				return e;
		return null;
	}

	/// Adds a new INPUT field to the end of the form with the given attributes.
	Element addInput(string name, string value, string type = "hidden") @safe pure {
		auto e = new Element(parentDocument, "input", null, true);
		e.setAttribute("name", name);
		e.setAttribute("value", value);
		e.setAttribute("type", type);

		appendChild(e);

		return e;
	}

	/// Removes the given field from the form. It finds the element and knocks it right out.
	void removeField(string name) @safe pure {
		foreach(e; getField(name))
			e.parentNode.removeChild(e);
	}

	/+
	/// Returns all form members.
	@property Element[] elements() {

	}

	///.
	string opDispatch(string name)(string v = null)
		// filter things that should actually be attributes on the form
		if( name != "method" && name != "action" && name != "enctype"
		 && name != "style"  && name != "name" && name != "id" && name != "class")
	{

	}
	+/
/+
	void submit() {
		// take its elements and submit them through http
	}
+/
}


/++
	Represents a HTML table. Has some convenience methods for working with tabular data.
+/
/// Group: implementations
class Table : Element {

	/// You can make this yourself but you'd generally get one of these object out of a html parse or [Element.make] call.
	this(Document _parentDocument) @safe pure {
		super(_parentDocument);
		tagName = "table";
	}

	/++
		Creates an element with the given type and content. The argument can be an Element, Html, or other data which is converted to text with `to!string`

		The element is $(I not) appended to the table.
	+/
	Element th(T)(T t) {
		Element e;
		if(parentDocument !is null)
			e = parentDocument.createElement("th");
		else
			e = Element.make("th");
		static if(is(T == Html))
			e.innerHTML = t;
		else static if(is(T : Element))
			e.appendChild(t);
		else
			e.innerText = to!string(t);
		return e;
	}

	/// ditto
	Element td(T)(T t) {
		Element e;
		if(parentDocument !is null)
			e = parentDocument.createElement("td");
		else
			e = Element.make("td");
		static if(is(T == Html))
			e.innerHTML = t;
		else static if(is(T : Element))
			e.appendChild(t);
		else
			e.innerText = to!string(t);
		return e;
	}

	/++
		Passes each argument to the [th] method for `appendHeaderRow` or [td] method for the others, appends them all to the `<tbody>` element for `appendRow`, `<thead>` element for `appendHeaderRow`, or a `<tfoot>` element for `appendFooterRow`, and ensures it is appended it to the table.
	+/
	Element appendHeaderRow(T...)(T t) {
		return appendRowInternal("th", "thead", t);
	}

	/// ditto
	Element appendFooterRow(T...)(T t) {
		return appendRowInternal("td", "tfoot", t);
	}

	/// ditto
	Element appendRow(T...)(T t) {
		return appendRowInternal("td", "tbody", t);
	}

	/++
		Takes each argument as a class name and calls [Element.addClass] for each element in the column associated with that index.

		Please note this does not use the html `<col>` element.
	+/
	void addColumnClasses(string[] classes...) @safe pure {
		auto grid = getGrid();
		foreach(row; grid)
		foreach(i, cl; classes) {
			if(cl.length)
			if(i < row.length)
				row[i].addClass(cl);
		}
	}

	private Element appendRowInternal(T...)(string innerType, string findType, T t) {
		Element row = Element.make("tr");

		foreach(e; t) {
			static if(is(typeof(e) : Element)) {
				if(e.tagName == "td" || e.tagName == "th")
					row.appendChild(e);
				else {
					Element a = Element.make(innerType);

					a.appendChild(e);

					row.appendChild(a);
				}
			} else static if(is(typeof(e) == Html)) {
				Element a = Element.make(innerType);
				a.innerHTML = e.source;
				row.appendChild(a);
			} else static if(is(typeof(e) == Element[])) {
				Element a = Element.make(innerType);
				foreach(ele; e)
					a.appendChild(ele);
				row.appendChild(a);
			} else static if(is(typeof(e) == string[])) {
				foreach(ele; e) {
					Element a = Element.make(innerType);
					a.innerText = to!string(ele);
					row.appendChild(a);
				}
			} else {
				Element a = Element.make(innerType);
				a.innerText = to!string(e);
				row.appendChild(a);
			}
		}

		foreach(e; children) {
			if(e.tagName == findType) {
				e.appendChild(row);
				return row;
			}
		}

		// the type was not found if we are here... let's add it so it is well-formed
		auto lol = this.addChild(findType);
		lol.appendChild(row);

		return row;
	}

	/// Returns the `<caption>` element of the table, creating one if it isn't there.
	Element captionElement() @safe pure {
		Element cap;
		foreach(c; children) {
			if(c.tagName == "caption") {
				cap = c;
				break;
			}
		}

		if(cap is null) {
			cap = Element.make("caption");
			appendChild(cap);
		}

		return cap;
	}

	/// Returns or sets the text inside the `<caption>` element, creating that element if it isnt' there.
	@property string caption() @safe pure {
		return captionElement().innerText;
	}

	/// ditto
	@property void caption(string text) @safe pure {
		captionElement().innerText = text;
	}

	/// Gets the logical layout of the table as a rectangular grid of
	/// cells. It considers rowspan and colspan. A cell with a large
	/// span is represented in the grid by being referenced several times.
	/// The tablePortition parameter can get just a <thead>, <tbody>, or
	/// <tfoot> portion if you pass one.
	///
	/// Note: the rectangular grid might include null cells.
	///
	/// This is kinda expensive so you should call once when you want the grid,
	/// then do lookups on the returned array.
	TableCell[][] getGrid(Element tablePortition = null) @safe pure
		in {
			if(tablePortition is null)
				assert(tablePortition is null);
			else {
				assert(tablePortition !is null);
				assert(tablePortition.parentNode is this);
				assert(
					tablePortition.tagName == "tbody"
					||
					tablePortition.tagName == "tfoot"
					||
					tablePortition.tagName == "thead"
				);
			}
		}
	do {
		if(tablePortition is null)
			tablePortition = this;

		TableCell[][] ret;

		// FIXME: will also return rows of sub tables!
		auto rows = tablePortition.getElementsByTagName("tr");
		ret.length = rows.length;

		int maxLength = 0;

		int insertCell(int row, int position, TableCell cell) {
			if(row >= ret.length)
				return position; // not supposed to happen - a rowspan is prolly too big.

			if(position == -1) {
				position++;
				foreach(item; ret[row]) {
					if(item is null)
						break;
					position++;
				}
			}

			if(position < ret[row].length)
				ret[row][position] = cell;
			else
				foreach(i; ret[row].length .. position + 1) {
					if(i == position)
						ret[row] ~= cell;
					else
						ret[row] ~= null;
				}
			return position;
		}

		foreach(i, rowElement; rows) {
			auto row = cast(TableRow) rowElement;
			assert(row !is null);
			assert(i < ret.length);

			int position = 0;
			foreach(cellElement; rowElement.childNodes) {
				auto cell = cast(TableCell) cellElement;
				if(cell is null)
					continue;

				// FIXME: colspan == 0 or rowspan == 0
				// is supposed to mean fill in the rest of
				// the table, not skip it
				foreach(int j; 0 .. cell.colspan) {
					foreach(int k; 0 .. cell.rowspan)
						// if the first row, always append.
						insertCell(k + cast(int) i, k == 0 ? -1 : position, cell);
					position++;
				}
			}

			if(ret[i].length > maxLength)
				maxLength = cast(int) ret[i].length;
		}

		// want to ensure it's rectangular
		foreach(ref r; ret) {
			foreach(i; r.length .. maxLength)
				r ~= null;
		}

		return ret;
	}
}

/// Represents a table row element - a <tr>
/// Group: implementations
class TableRow : Element {
	///.
	this(Document _parentDocument) @safe pure {
		super(_parentDocument);
		tagName = "tr";
	}

	// FIXME: the standard says there should be a lot more in here,
	// but meh, I never use it and it's a pain to implement.
}

/// Represents anything that can be a table cell - <td> or <th> html.
/// Group: implementations
class TableCell : Element {
	///.
	this(Document _parentDocument, string _tagName) @safe pure {
		super(_parentDocument, _tagName);
	}

	/// Gets and sets the row/colspan attributes as integers
	@property int rowspan() const @safe pure {
		int ret = 1;
		auto it = getAttribute("rowspan");
		if(it.length)
			ret = to!int(it);
		return ret;
	}

	/// ditto
	@property int colspan() const @safe pure {
		int ret = 1;
		auto it = getAttribute("colspan");
		if(it.length)
			ret = to!int(it);
		return ret;
	}

	/// ditto
	@property int rowspan(int i) @safe pure {
		setAttribute("rowspan", to!string(i));
		return i;
	}

	/// ditto
	@property int colspan(int i) @safe pure {
		setAttribute("colspan", to!string(i));
		return i;
	}

}


/// This is thrown on parse errors.
/// Group: implementations
class MarkupException : Exception {

	///.
	this(string message, string file = __FILE__, size_t line = __LINE__) @safe pure {
		super(message, file, line);
	}
}

/// This is used when you are using one of the require variants of navigation, and no matching element can be found in the tree.
/// Group: implementations
class ElementNotFoundException : Exception {

	/// type == kind of element you were looking for and search == a selector describing the search.
	this(string type, string search, Element searchContext, string file = __FILE__, size_t line = __LINE__) @safe pure {
		this.searchContext = searchContext;
		super("Element of type '"~type~"' matching {"~search~"} not found.", file, line);
	}

	Element searchContext;
}

/// The html struct is used to differentiate between regular text nodes and html in certain functions
///
/// Easiest way to construct it is like this: `auto html = Html("<p>hello</p>");`
/// Group: core_functionality
struct Html {
	/// This string holds the actual html. Use it to retrieve the contents.
	string source;
}

// for the observers
enum DomMutationOperations {
	setAttribute,
	removeAttribute,
	appendChild, // tagname, attributes[], innerHTML
	insertBefore,
	truncateChildren,
	removeChild,
	appendHtml,
	replaceHtml,
	appendText,
	replaceText,
	replaceTextOnly
}

// and for observers too
struct DomMutationEvent {
	DomMutationOperations operation;
	Element target;
	Element related; // what this means differs with the operation
	Element related2;
	string relatedString;
	string relatedString2;
}


private immutable static string[] htmlSelfClosedElements = [
	// html 4
	"area","base","br","col","hr","img","input","link","meta","param",

	// html 5
	"embed","source","track","wbr"
];

private immutable static string[] htmlRawSourceElements = [
	"script", "style"
];

private immutable static string[] htmlInlineElements = [
	"span", "strong", "em", "b", "i", "a"
];


/// helper function for decoding html entities
int intFromHex(string hex) @safe pure {
	int place = 1;
	int value = 0;
	for(sizediff_t a = hex.length - 1; a >= 0; a--) {
		int v;
		char q = hex[a];
		if( q >= '0' && q <= '9')
			v = q - '0';
		else if (q >= 'a' && q <= 'f')
			v = q - 'a' + 10;
		else if (q >= 'A' && q <= 'F')
			v = q - 'A' + 10;
		else throw new Exception("Illegal hex character: " ~ q);

		value += v * place;

		place *= 16;
	}

	return value;
}


// CSS selector handling

// EXTENSIONS
// dd - dt means get the dt directly before that dd (opposite of +)                  NOT IMPLEMENTED
// dd -- dt means rewind siblings until you hit a dt, go as far as you need to       NOT IMPLEMENTED
// dt < dl means get the parent of that dt iff it is a dl (usable for "get a dt that are direct children of dl")
// dt << dl  means go as far up as needed to find a dl (you have an element and want its containers)      NOT IMPLEMENTED
// :first  means to stop at the first hit, don't do more (so p + p == p ~ p:first



// CSS4 draft currently says you can change the subject (the element actually returned) by putting a ! at the end of it.
// That might be useful to implement, though I do have parent selectors too.

		///.
		static immutable string[] selectorTokens = [
			// It is important that the 2 character possibilities go first here for accurate lexing
		    "~=", "*=", "|=", "^=", "$=", "!=",
		    "::", ">>",
		    "<<", // my any-parent extension (reciprocal of whitespace)
		    // " - ", // previous-sibling extension (whitespace required to disambiguate tag-names)
		    ".", ">", "+", "*", ":", "[", "]", "=", "\"", "#", ",", " ", "~", "<", "(", ")"
		]; // other is white space or a name.

		///.
		sizediff_t idToken(string str, sizediff_t position) @safe pure {
			sizediff_t tid = -1;
			char c = str[position];
			foreach(a, token; selectorTokens)

				if(c == token[0]) {
					if(token.length > 1) {
						if(position + 1 >= str.length   ||   str[position+1] != token[1])
							continue; // not this token
					}
					tid = a;
					break;
				}
			return tid;
		}

	/// Parts of the CSS selector implementation
	// look, ma, no phobos!
	// new lexer by ketmar
	string[] lexSelector (string selstr) @safe pure {

		static sizediff_t idToken (string str, size_t stpos) {
			char c = str[stpos];
			foreach (sizediff_t tidx, immutable token; selectorTokens) {
				if (c == token[0]) {
					if (token.length > 1) {
						assert(token.length == 2, token); // we don't have 3-char tokens yet
						if (str.length-stpos < 2 || str[stpos+1] != token[1]) continue;
					}
					return tidx;
				}
			}
			return -1;
		}

		// skip spaces and comments
		static string removeLeadingBlanks (string str) {
			size_t curpos = 0;
			while (curpos < str.length) {
				immutable char ch = str[curpos];
				// this can overflow on 4GB strings on 32-bit; 'cmon, don't be silly, nobody cares!
				if (ch == '/' && str.length-curpos > 1 && str[curpos+1] == '*') {
					// comment
					curpos += 2;
					while (curpos < str.length) {
						if (str[curpos] == '*' && str.length-curpos > 1 && str[curpos+1] == '/') {
							curpos += 2;
							break;
						}
						++curpos;
					}
				} else if (ch < 32) { // The < instead of <= is INTENTIONAL. See note from adr below.
					++curpos;

					// FROM ADR: This does NOT catch ' '! Spaces have semantic meaning in CSS! While
					// "foo bar" is clear, and can only have one meaning, consider ".foo .bar".
					// That is not the same as ".foo.bar". If the space is stripped, important
					// information is lost, despite the tokens being separatable anyway.
					//
					// The parser really needs to be aware of the presence of a space.
				} else {
					break;
				}
			}
			return str[curpos..$];
		}

		static bool isBlankAt() (string str, size_t pos) {
			// we should consider unicode spaces too, but... unicode sux anyway.
			return
				(pos < str.length && // in string
				 (str[pos] <= 32 || // space
					(str.length-pos > 1 && str[pos] == '/' && str[pos+1] == '*'))); // comment
		}

		string[] tokens;
		// lexx it!
		while ((selstr = removeLeadingBlanks(selstr)).length > 0) {
			if(selstr[0] == '\"' || selstr[0] == '\'') {
				auto end = selstr[0];
				auto pos = 1;
				bool escaping;
				while(pos < selstr.length && !escaping && selstr[pos] != end) {
					if(escaping)
						escaping = false;
					else if(selstr[pos] == '\\')
						escaping = true;
					pos++;
				}

				// FIXME: do better unescaping
				tokens ~= selstr[1 .. pos].replace(`\"`, `"`).replace(`\'`, `'`).replace(`\\`, `\`);
				if(pos+1 >= selstr.length)
					assert(0, selstr);
				selstr = selstr[pos + 1.. $];
				continue;
			}


			// no tokens starts with escape
			immutable tid = idToken(selstr, 0);
			if (tid >= 0) {
				// special token
				tokens ~= selectorTokens[tid]; // it's funnier this way
				selstr = selstr[selectorTokens[tid].length..$];
				continue;
			}
			// from start to space or special token
			size_t escapePos = size_t.max;
			size_t curpos = 0; // i can has chizburger^w escape at the start
			while (curpos < selstr.length) {
				if (selstr[curpos] == '\\') {
					// this is escape, just skip it and next char
					if (escapePos == size_t.max) escapePos = curpos;
					curpos = (selstr.length-curpos >= 2 ? curpos+2 : selstr.length);
				} else {
					if (isBlankAt(selstr, curpos) || idToken(selstr, curpos) >= 0) break;
					++curpos;
				}
			}
			// identifier
			if (escapePos != size_t.max) {
				// i hate it when it happens
				string id = selstr[0..escapePos];
				while (escapePos < curpos) {
					if (curpos-escapePos < 2) break;
					id ~= selstr[escapePos+1]; // escaped char
					escapePos += 2;
					immutable stp = escapePos;
					while (escapePos < curpos && selstr[escapePos] != '\\') ++escapePos;
					if (escapePos > stp) id ~= selstr[stp..escapePos];
				}
				if (id.length > 0) tokens ~= id;
			} else {
				tokens ~= selstr[0..curpos];
			}
			selstr = selstr[curpos..$];
		}
		return tokens;
	}
	version(unittest_domd_lexer) @safe pure unittest {
		assert(lexSelector(r" test\=me  /*d*/") == [r"test=me"]);
		assert(lexSelector(r"div/**/. id") == ["div", ".", "id"]);
		assert(lexSelector(r" < <") == ["<", "<"]);
		assert(lexSelector(r" <<") == ["<<"]);
		assert(lexSelector(r" <</") == ["<<", "/"]);
		assert(lexSelector(r" <</*") == ["<<"]);
		assert(lexSelector(r" <\</*") == ["<", "<"]);
		assert(lexSelector(r"heh\") == ["heh"]);
		assert(lexSelector(r"alice \") == ["alice"]);
		assert(lexSelector(r"alice,is#best") == ["alice", ",", "is", "#", "best"]);
	}

	/// ditto
	static struct SelectorPart {
		string tagNameFilter; ///.
		string[] attributesPresent; /// [attr]
		string[2][] attributesEqual; /// [attr=value]
		string[2][] attributesStartsWith; /// [attr^=value]
		string[2][] attributesEndsWith; /// [attr$=value]
		// split it on space, then match to these
		string[2][] attributesIncludesSeparatedBySpaces; /// [attr~=value]
		// split it on dash, then match to these
		string[2][] attributesIncludesSeparatedByDashes; /// [attr|=value]
		string[2][] attributesInclude; /// [attr*=value]
		string[2][] attributesNotEqual; /// [attr!=value] -- extension by me

		string[] hasSelectors; /// :has(this)
		string[] notSelectors; /// :not(this)

		string[] isSelectors; /// :is(this)
		string[] whereSelectors; /// :where(this)

		ParsedNth[] nthOfType; /// .
		ParsedNth[] nthLastOfType; /// .
		ParsedNth[] nthChild; /// .

		bool firstChild; ///.
		bool lastChild; ///.

		bool firstOfType; /// .
		bool lastOfType; /// .

		bool emptyElement; ///.
		bool whitespaceOnly; ///
		bool oddChild; ///.
		bool evenChild; ///.

		bool scopeElement; /// the css :scope thing; matches just the `this` element. NOT IMPLEMENTED

		bool rootElement; ///.

		int separation = -1; /// -1 == only itself; the null selector, 0 == tree, 1 == childNodes, 2 == childAfter, 3 == youngerSibling, 4 == parentOf

		bool isCleanSlateExceptSeparation() @safe pure {
			auto cp = this;
			cp.separation = -1;
			return cp is SelectorPart.init;
		}

		///.
		string toString() @safe pure {
			string ret;
			switch(separation) {
				default: assert(0);
				case -1: break;
				case 0: ret ~= " "; break;
				case 1: ret ~= " > "; break;
				case 2: ret ~= " + "; break;
				case 3: ret ~= " ~ "; break;
				case 4: ret ~= " < "; break;
			}
			ret ~= tagNameFilter;
			foreach(a; attributesPresent) ret ~= "[" ~ a ~ "]";
			foreach(a; attributesEqual) ret ~= "[" ~ a[0] ~ "=\"" ~ a[1] ~ "\"]";
			foreach(a; attributesEndsWith) ret ~= "[" ~ a[0] ~ "$=\"" ~ a[1] ~ "\"]";
			foreach(a; attributesStartsWith) ret ~= "[" ~ a[0] ~ "^=\"" ~ a[1] ~ "\"]";
			foreach(a; attributesNotEqual) ret ~= "[" ~ a[0] ~ "!=\"" ~ a[1] ~ "\"]";
			foreach(a; attributesInclude) ret ~= "[" ~ a[0] ~ "*=\"" ~ a[1] ~ "\"]";
			foreach(a; attributesIncludesSeparatedByDashes) ret ~= "[" ~ a[0] ~ "|=\"" ~ a[1] ~ "\"]";
			foreach(a; attributesIncludesSeparatedBySpaces) ret ~= "[" ~ a[0] ~ "~=\"" ~ a[1] ~ "\"]";

			foreach(a; notSelectors) ret ~= ":not(" ~ a ~ ")";
			foreach(a; hasSelectors) ret ~= ":has(" ~ a ~ ")";

			foreach(a; isSelectors) ret ~= ":is(" ~ a ~ ")";
			foreach(a; whereSelectors) ret ~= ":where(" ~ a ~ ")";

			foreach(a; nthChild) ret ~= ":nth-child(" ~ a.toString ~ ")";
			foreach(a; nthOfType) ret ~= ":nth-of-type(" ~ a.toString ~ ")";
			foreach(a; nthLastOfType) ret ~= ":nth-last-of-type(" ~ a.toString ~ ")";

			if(firstChild) ret ~= ":first-child";
			if(lastChild) ret ~= ":last-child";
			if(firstOfType) ret ~= ":first-of-type";
			if(lastOfType) ret ~= ":last-of-type";
			if(emptyElement) ret ~= ":empty";
			if(whitespaceOnly) ret ~= ":whitespace-only";
			if(oddChild) ret ~= ":odd-child";
			if(evenChild) ret ~= ":even-child";
			if(rootElement) ret ~= ":root";
			if(scopeElement) ret ~= ":scope";

			return ret;
		}

		// USEFUL
		/// Returns true if the given element matches this part
		bool matchElement(Element e, Element scopeElementNow = null) @safe pure {
			// FIXME: this can be called a lot of times, and really add up in times according to the profiler.
			// Each individual call is reasonably fast already, but it adds up.
			if(e is null) return false;
			if(e.nodeType != 1) return false;

			if(tagNameFilter != "" && tagNameFilter != "*")
				if(e.tagName != tagNameFilter)
					return false;
			if(firstChild) {
				if(e.parentNode is null)
					return false;
				if(e.parentNode.childElements[0] !is e)
					return false;
			}
			if(lastChild) {
				if(e.parentNode is null)
					return false;
				auto ce = e.parentNode.childElements;
				if(ce[$-1] !is e)
					return false;
			}
			if(firstOfType) {
				if(e.parentNode is null)
					return false;
				auto ce = e.parentNode.childElements;
				foreach(c; ce) {
					if(c.tagName == e.tagName) {
						if(c is e)
							return true;
						else
							return false;
					}
				}
			}
			if(lastOfType) {
				if(e.parentNode is null)
					return false;
				auto ce = e.parentNode.childElements;
				foreach_reverse(c; ce) {
					if(c.tagName == e.tagName) {
						if(c is e)
							return true;
						else
							return false;
					}
				}
			}
			if(scopeElement) {
				if(e !is scopeElementNow)
					return false;
			}
			if(emptyElement) {
				if(e.isEmpty())
					return false;
			}
			if(whitespaceOnly) {
				if(e.innerText.strip.length)
					return false;
			}
			if(rootElement) {
				if(e.parentNode !is null)
					return false;
			}
			if(oddChild || evenChild) {
				if(e.parentNode is null)
					return false;
				foreach(i, child; e.parentNode.childElements) {
					if(child is e) {
						if(oddChild && !(i&1))
							return false;
						if(evenChild && (i&1))
							return false;
						break;
					}
				}
			}

			foreach(a; attributesPresent)
				if(a !in e.attributes)
					return false;
			foreach(a; attributesEqual)
				if(e.getAttribute(a[0]) != a[1])
					return false;
			foreach(a; attributesNotEqual)
				// FIXME: maybe it should say null counts... this just bit me.
				// I did [attr][attr!=value] to work around.
				//
				// if it's null, it's not equal, right?
				//if(a[0] !in e.attributes || e.attributes[a[0]] == a[1])
				if(e.getAttribute(a[0]) == a[1])
					return false;
			foreach(a; attributesInclude)
				if(e.getAttribute(a[0]).indexOf(a[1]) == -1)
					return false;
			foreach(a; attributesStartsWith)
				if(!e.getAttribute(a[0]).startsWith(a[1]))
					return false;
			foreach(a; attributesEndsWith)
				if(!e.getAttribute(a[0]).endsWith(a[1]))
					return false;
			foreach(a; attributesIncludesSeparatedBySpaces)
				if(!e.getAttribute(a[0]).splitter!isWhite.canFind(a[1]))
					return false;
			foreach(a; attributesIncludesSeparatedByDashes)
				if(!e.getAttribute(a[0]).splitter("-").canFind(a[1]))
					return false;
			foreach(a; hasSelectors) {
				if(e.querySelector(a) is null)
					return false;
			}
			foreach(a; notSelectors) {
				auto sel = Selector(a);
				if(sel.matchesElement(e))
					return false;
			}
			foreach(a; isSelectors) {
				auto sel = Selector(a);
				if(!sel.matchesElement(e))
					return false;
			}
			foreach(a; whereSelectors) {
				auto sel = Selector(a);
				if(!sel.matchesElement(e))
					return false;
			}

			foreach(a; nthChild) {
				if(e.parentNode is null)
					return false;

				auto among = e.parentNode.childElements;

				if(!a.solvesFor(among, e))
					return false;
			}
			foreach(a; nthOfType) {
				if(e.parentNode is null)
					return false;

				auto among = e.parentNode.childElements(e.tagName);

				if(!a.solvesFor(among, e))
					return false;
			}
			foreach(a; nthLastOfType) {
				if(e.parentNode is null)
					return false;

				auto among = retro(e.parentNode.childElements(e.tagName));

				if(!a.solvesFor(among, e))
					return false;
			}

			return true;
		}
	}

	static struct ParsedNth {
		int multiplier;
		int adder;

		string of;

		this(string text) @safe pure {
			auto original = text;
			consumeWhitespace(text);
			if(text.startsWith("odd")) {
				multiplier = 2;
				adder = 1;

				text = text[3 .. $];
			} else if(text.startsWith("even")) {
				multiplier = 2;
				adder = 1;

				text = text[4 .. $];
			} else {
				int n = (text.length && text[0] == 'n') ? 1 : parseNumber(text);
				consumeWhitespace(text);
				if(text.length && text[0] == 'n') {
					multiplier = n;
					text = text[1 .. $];
					consumeWhitespace(text);
					if(text.length) {
						if(text[0] == '+') {
							text = text[1 .. $];
							adder = parseNumber(text);
						} else if(text[0] == '-') {
							text = text[1 .. $];
							adder = -parseNumber(text);
						} else if(text[0] == 'o') {
							// continue, this is handled below
						} else
							throw new Exception("invalid css string at " ~ text ~ " in " ~ original);
					}
				} else {
					adder = n;
				}
			}

			consumeWhitespace(text);
			if(text.startsWith("of")) {
				text = text[2 .. $];
				consumeWhitespace(text);
				of = text[0 .. $];
			}
		}

		string toString() @safe pure {
			return format("%dn%s%d%s%s", multiplier, adder >= 0 ? "+" : "", adder, of.length ? " of " : "", of);
		}

		bool solvesFor(R)(R elements, Element e) {
			int idx = 1;
			bool found = false;
			foreach(ele; elements) {
				if(of.length) {
					auto sel = Selector(of);
					if(!sel.matchesElement(ele))
						continue;
				}
				if(ele is e) {
					found = true;
					break;
				}
				idx++;
			}
			if(!found) return false;

			// multiplier* n + adder = idx
			// if there is a solution for integral n, it matches

			idx -= adder;
			if(multiplier) {
				if(idx % multiplier == 0)
					return true;
			} else {
				return idx == 0;
			}
			return false;
		}

		private void consumeWhitespace(ref string text) @safe pure {
			while(text.length && text[0] == ' ')
				text = text[1 .. $];
		}

		private int parseNumber(ref string text) @safe pure {
			consumeWhitespace(text);
			if(text.length == 0) return 0;
			bool negative = text[0] == '-';
			if(text[0] == '+')
				text = text[1 .. $];
			if(negative) text = text[1 .. $];
			int i = 0;
			while(i < text.length && (text[i] >= '0' && text[i] <= '9'))
				i++;
			if(i == 0)
				return 0;
			int cool = to!int(text[0 .. i]);
			text = text[i .. $];
			return negative ? -cool : cool;
		}
	}

	// USEFUL
	/// ditto
	Element[] getElementsBySelectorParts(Element start, SelectorPart[] parts, Element scopeElementNow = null) @safe pure {
		Element[] ret;
		if(!parts.length) {
			return [start]; // the null selector only matches the start point; it
				// is what terminates the recursion
		}

		auto part = parts[0];
		//writeln("checking ", part, " against ", start, " with ", part.separation);
		switch(part.separation) {
			default: assert(0);
			case -1:
			case 0: // tree
				foreach(e; start.tree) {
					if(part.separation == 0 && start is e)
						continue; // space doesn't match itself!
					if(part.matchElement(e, scopeElementNow)) {
						ret ~= getElementsBySelectorParts(e, parts[1..$], scopeElementNow);
					}
				}
			break;
			case 1: // children
				foreach(e; start.childNodes) {
					if(part.matchElement(e, scopeElementNow)) {
						ret ~= getElementsBySelectorParts(e, parts[1..$], scopeElementNow);
					}
				}
			break;
			case 2: // next-sibling
				auto e = start.nextSibling("*");
				if(part.matchElement(e, scopeElementNow))
					ret ~= getElementsBySelectorParts(e, parts[1..$], scopeElementNow);
			break;
			case 3: // younger sibling
				auto tmp = start.parentNode;
				if(tmp !is null) {
					sizediff_t pos = -1;
					auto children = tmp.childElements;
					foreach(i, child; children) {
						if(child is start) {
							pos = i;
							break;
						}
					}
					assert(pos != -1);
					foreach(e; children[pos+1..$]) {
						if(part.matchElement(e, scopeElementNow))
							ret ~= getElementsBySelectorParts(e, parts[1..$], scopeElementNow);
					}
				}
			break;
			case 4: // immediate parent node, an extension of mine to walk back up the tree
				auto e = start.parentNode;
				if(part.matchElement(e, scopeElementNow)) {
					ret ~= getElementsBySelectorParts(e, parts[1..$], scopeElementNow);
				}
				/*
					Example of usefulness:

					Consider you have an HTML table. If you want to get all rows that have a th, you can do:

					table th < tr

					Get all th descendants of the table, then walk back up the tree to fetch their parent tr nodes
				*/
			break;
			case 5: // any parent note, another extension of mine to go up the tree (backward of the whitespace operator)
				/*
					Like with the < operator, this is best used to find some parent of a particular known element.

					Say you have an anchor inside a
				*/
		}

		return ret;
	}

	/++
		Represents a parsed CSS selector. You never have to use this directly, but you can if you know it is going to be reused a lot to avoid a bit of repeat parsing.

		See_Also:
			$(LIST
				* [Element.querySelector]
				* [Element.querySelectorAll]
				* [Element.matches]
				* [Element.closest]
				* [Document.querySelector]
				* [Document.querySelectorAll]
			)
	+/
	/// Group: core_functionality
	static struct Selector {
		SelectorComponent[] components;
		string original;
		/++
			Parses the selector string and constructs the usable structure.
		+/
		this(string cssSelector) @safe pure {
			components = parseSelectorString(cssSelector);
			original = cssSelector;
		}

		/++
			Returns true if the given element matches this selector,
			considered relative to an arbitrary element.

			You can do a form of lazy [Element.querySelectorAll|querySelectorAll] by using this
			with [std.algorithm.iteration.filter]:

			---
			Selector sel = Selector("foo > bar");
			auto lazySelectorRange = element.tree.filter!(e => sel.matchElement(e))(document.root);
			---
		+/
		bool matchesElement(Element e, Element relativeTo = null) @safe pure {
			foreach(component; components)
				if(component.matchElement(e, relativeTo))
					return true;

			return false;
		}

		/++
			Reciprocal of [Element.querySelectorAll]
		+/
		Element[] getMatchingElements(Element start, Element relativeTo = null) @safe pure {
			Element[] ret;
			foreach(component; components)
				ret ~= getElementsBySelectorParts(start, component.parts, relativeTo);
			return removeDuplicates(ret);
		}

		/++
			Like [getMatchingElements], but returns a lazy range. Be careful
			about mutating the dom as you iterate through this.
		+/
		auto getMatchingElementsLazy(Element start, Element relativeTo = null) @safe pure {
			return start.tree.filter!(a => this.matchesElement(a, relativeTo));
		}


		/// Returns the string this was built from
		string toString() @safe pure {
			return original;
		}

		/++
			Returns a string from the parsed result


			(may not match the original, this is mostly for debugging right now but in the future might be useful for pretty-printing)
		+/
		string parsedToString() @safe pure {
			string ret;

			foreach(idx, component; components) {
				if(idx) ret ~= ", ";
				ret ~= component.toString();
			}

			return ret;
		}
	}

	///.
	static struct SelectorComponent {
		///.
		SelectorPart[] parts;

		///.
		string toString() @safe pure {
			string ret;
			foreach(part; parts)
				ret ~= part.toString();
			return ret;
		}

		// USEFUL
		///.
		Element[] getElements(Element start, Element relativeTo = null) @safe pure {
			return removeDuplicates(getElementsBySelectorParts(start, parts, relativeTo));
		}

		// USEFUL (but not implemented)
		/// If relativeTo == null, it assumes the root of the parent document.
		bool matchElement(Element e, Element relativeTo = null) @safe pure {
			if(e is null) return false;
			Element where = e;
			int lastSeparation = -1;

			auto lparts = parts;

			if(parts.length && parts[0].separation > 0) {
				throw new Exception("invalid selector");
			/+
				// if it starts with a non-trivial separator, inject
				// a "*" matcher to act as a root. for cases like document.querySelector("> body")
				// which implies html

				// however, if it is a child-matching selector and there are no children,
				// bail out early as it obviously cannot match.
				bool hasNonTextChildren = false;
				foreach(c; e.children)
					if(c.nodeType != 3) {
						hasNonTextChildren = true;
						break;
					}
				if(!hasNonTextChildren)
					return false;

				// there is probably a MUCH better way to do this.
				auto dummy = SelectorPart.init;
				dummy.tagNameFilter = "*";
				dummy.separation = 0;
				lparts = dummy ~ lparts;
			+/
			}

			foreach(part; retro(lparts)) {

				 // writeln("matching ", where, " with ", part, " via ", lastSeparation);
				 // writeln(parts);

				if(lastSeparation == -1) {
					if(!part.matchElement(where, relativeTo))
						return false;
				} else if(lastSeparation == 0) { // generic parent
					// need to go up the whole chain
					where = where.parentNode;

					while(where !is null) {
						if(part.matchElement(where, relativeTo))
							break;

						if(where is relativeTo)
							return false;

						where = where.parentNode;
					}

					if(where is null)
						return false;
				} else if(lastSeparation == 1) { // the > operator
					where = where.parentNode;

					if(!part.matchElement(where, relativeTo))
						return false;
				} else if(lastSeparation == 2) { // the + operator
				//writeln("WHERE", where, " ", part);
					where = where.previousSibling("*");

					if(!part.matchElement(where, relativeTo))
						return false;
				} else if(lastSeparation == 3) { // the ~ operator
					where = where.previousSibling("*");
					while(where !is null) {
						if(part.matchElement(where, relativeTo))
							break;

						if(where is relativeTo)
							return false;

						where = where.previousSibling("*");
					}

					if(where is null)
						return false;
				} else if(lastSeparation == 4) { // my bad idea extension < operator, don't use this anymore
					// FIXME
				}

				lastSeparation = part.separation;

				/*
					/+
					I commented this to magically make unittest pass and I think the reason it works
					when commented is that I inject a :scope iff there's a selector at top level now
					and if not, it follows the (frankly stupid) w3c standard behavior at arbitrary id
					asduiwh . but me injecting the :scope also acts as a terminating condition.

					tbh this prolly needs like a trillion more tests.
					+/
				if(where is relativeTo)
					return false; // at end of line, if we aren't done by now, the match fails
				*/
			}
			return true; // if we got here, it is a success
		}

		// the string should NOT have commas. Use parseSelectorString for that instead
		///.
		static SelectorComponent fromString(string selector) @safe pure {
			return parseSelector(lexSelector(selector));
		}
	}

	///.
	SelectorComponent[] parseSelectorString(string selector, bool caseSensitiveTags = true) @safe pure {
		SelectorComponent[] ret;
		auto tokens = lexSelector(selector); // this will parse commas too
		// and now do comma-separated slices (i haz phobosophobia!)
		int parensCount = 0;
		while (tokens.length > 0) {
			size_t end = 0;
			while (end < tokens.length && (parensCount > 0 || tokens[end] != ",")) {
				if(tokens[end] == "(") parensCount++;
				if(tokens[end] == ")") parensCount--;
				++end;
			}
			if (end > 0) ret ~= parseSelector(tokens[0..end], caseSensitiveTags);
			if (tokens.length-end < 2) break;
			tokens = tokens[end+1..$];
		}
		return ret;
	}

	///.
	SelectorComponent parseSelector(string[] tokens, bool caseSensitiveTags = true) @safe pure {
		SelectorComponent s;

		SelectorPart current;
		void commit() {
			// might as well skip null items
			if(!current.isCleanSlateExceptSeparation()) {
				s.parts ~= current;
				current = current.init; // start right over
			}
		}
		enum State {
			Starting,
			ReadingClass,
			ReadingId,
			ReadingAttributeSelector,
			ReadingAttributeComparison,
			ExpectingAttributeCloser,
			ReadingPseudoClass,
			ReadingAttributeValue,

			SkippingFunctionalSelector,
		}
		State state = State.Starting;
		string attributeName, attributeValue, attributeComparison;
		int parensCount;
		foreach(idx, token; tokens) {
			string readFunctionalSelector() {
				string s;
				if(tokens[idx + 1] != "(")
					throw new Exception("parse error");
				int pc = 1;
				foreach(t; tokens[idx + 2 .. $]) {
					if(t == "(")
						pc++;
					if(t == ")")
						pc--;
					if(pc == 0)
						break;
					s ~= t;
				}

				return s;
			}

			sizediff_t tid = -1;
			foreach(i, item; selectorTokens)
				if(token == item) {
					tid = i;
					break;
				}
			final switch(state) {
				case State.Starting: // fresh, might be reading an operator or a tagname
					if(tid == -1) {
						if(!caseSensitiveTags)
							token = token.toLower();

						if(current.isCleanSlateExceptSeparation()) {
							current.tagNameFilter = token;
							// default thing, see comment under "*" below
							if(current.separation == -1) current.separation = 0;
						} else {
							// if it was already set, we must see two thingies
							// separated by whitespace...
							commit();
							current.separation = 0; // tree
							current.tagNameFilter = token;
						}
					} else {
						// Selector operators
						switch(token) {
							case "*":
								current.tagNameFilter = "*";
								// the idea here is if we haven't actually set a separation
								// yet (e.g. the > operator), it should assume the generic
								// whitespace (descendant) mode to avoid matching self with -1
								if(current.separation == -1) current.separation = 0;
							break;
							case " ":
								// If some other separation has already been set,
								// this is irrelevant whitespace, so we should skip it.
								// this happens in the case of "foo > bar" for example.
								if(current.isCleanSlateExceptSeparation() && current.separation > 0)
									continue;
								commit();
								current.separation = 0; // tree
							break;
							case ">>":
								commit();
								current.separation = 0; // alternate syntax for tree from html5 css
							break;
							case ">":
								commit();
								current.separation = 1; // child
							break;
							case "+":
								commit();
								current.separation = 2; // sibling directly after
							break;
							case "~":
								commit();
								current.separation = 3; // any sibling after
							break;
							case "<":
								commit();
								current.separation = 4; // immediate parent of
							break;
							case "[":
								state = State.ReadingAttributeSelector;
								if(current.separation == -1) current.separation = 0;
							break;
							case ".":
								state = State.ReadingClass;
								if(current.separation == -1) current.separation = 0;
							break;
							case "#":
								state = State.ReadingId;
								if(current.separation == -1) current.separation = 0;
							break;
							case ":":
							case "::":
								state = State.ReadingPseudoClass;
								if(current.separation == -1) current.separation = 0;
							break;

							default:
								assert(0, token);
						}
					}
				break;
				case State.ReadingClass:
					current.attributesIncludesSeparatedBySpaces ~= ["class", token];
					state = State.Starting;
				break;
				case State.ReadingId:
					current.attributesEqual ~= ["id", token];
					state = State.Starting;
				break;
				case State.ReadingPseudoClass:
					switch(token) {
						case "first-of-type":
							current.firstOfType = true;
						break;
						case "last-of-type":
							current.lastOfType = true;
						break;
						case "only-of-type":
							current.firstOfType = true;
							current.lastOfType = true;
						break;
						case "first-child":
							current.firstChild = true;
						break;
						case "last-child":
							current.lastChild = true;
						break;
						case "only-child":
							current.firstChild = true;
							current.lastChild = true;
						break;
						case "scope":
							current.scopeElement = true;
						break;
						case "empty":
							// one with no children
							current.emptyElement = true;
						break;
						case "whitespace-only":
							current.whitespaceOnly = true;
						break;
						case "link":
							current.attributesPresent ~= "href";
						break;
						case "root":
							current.rootElement = true;
						break;
						case "nth-child":
							current.nthChild ~= ParsedNth(readFunctionalSelector());
							state = State.SkippingFunctionalSelector;
						continue;
						case "nth-of-type":
							current.nthOfType ~= ParsedNth(readFunctionalSelector());
							state = State.SkippingFunctionalSelector;
						continue;
						case "nth-last-of-type":
							current.nthLastOfType ~= ParsedNth(readFunctionalSelector());
							state = State.SkippingFunctionalSelector;
						continue;
						case "is":
							state = State.SkippingFunctionalSelector;
							current.isSelectors ~= readFunctionalSelector();
						continue; // now the rest of the parser skips past the parens we just handled
						case "where":
							state = State.SkippingFunctionalSelector;
							current.whereSelectors ~= readFunctionalSelector();
						continue; // now the rest of the parser skips past the parens we just handled
						case "not":
							state = State.SkippingFunctionalSelector;
							current.notSelectors ~= readFunctionalSelector();
						continue; // now the rest of the parser skips past the parens we just handled
						case "has":
							state = State.SkippingFunctionalSelector;
							current.hasSelectors ~= readFunctionalSelector();
						continue; // now the rest of the parser skips past the parens we just handled
						// back to standards though not quite right lol
						case "disabled":
							current.attributesPresent ~= "disabled";
						break;
						case "checked":
							current.attributesPresent ~= "checked";
						break;

						case "visited", "active", "hover", "target", "focus", "selected":
							current.attributesPresent ~= "nothing";
							// FIXME
						/+
						// extensions not implemented
						//case "text": // takes the text in the element and wraps it in an element, returning it
						+/
							goto case;
						case "before", "after":
							current.attributesPresent ~= "FIXME";

						break;
						// My extensions
						case "odd-child":
							current.oddChild = true;
						break;
						case "even-child":
							current.evenChild = true;
						break;
						default:
							//if(token.indexOf("lang") == -1)
							//assert(0, token);
						break;
					}
					state = State.Starting;
				break;
				case State.SkippingFunctionalSelector:
					if(token == "(") {
						parensCount++;
					} else if(token == ")") {
						parensCount--;
					}

					if(parensCount == 0)
						state = State.Starting;
				break;
				case State.ReadingAttributeSelector:
					attributeName = token;
					attributeComparison = null;
					attributeValue = null;
					state = State.ReadingAttributeComparison;
				break;
				case State.ReadingAttributeComparison:
					// FIXME: these things really should be quotable in the proper lexer...
					if(token != "]") {
						if(token.indexOf("=") == -1) {
							// not a comparison; consider it
							// part of the attribute
							attributeValue ~= token;
						} else {
							attributeComparison = token;
							state = State.ReadingAttributeValue;
						}
						break;
					}
					goto case;
				case State.ExpectingAttributeCloser:
					if(token != "]") {
						// not the closer; consider it part of comparison
						if(attributeComparison == "")
							attributeName ~= token;
						else
							attributeValue ~= token;
						break;
					}

					// Selector operators
					switch(attributeComparison) {
						default: assert(0);
						case "":
							current.attributesPresent ~= attributeName;
						break;
						case "=":
							current.attributesEqual ~= [attributeName, attributeValue];
						break;
						case "|=":
							current.attributesIncludesSeparatedByDashes ~= [attributeName, attributeValue];
						break;
						case "~=":
							current.attributesIncludesSeparatedBySpaces ~= [attributeName, attributeValue];
						break;
						case "$=":
							current.attributesEndsWith ~= [attributeName, attributeValue];
						break;
						case "^=":
							current.attributesStartsWith ~= [attributeName, attributeValue];
						break;
						case "*=":
							current.attributesInclude ~= [attributeName, attributeValue];
						break;
						case "!=":
							current.attributesNotEqual ~= [attributeName, attributeValue];
						break;
					}

					state = State.Starting;
				break;
				case State.ReadingAttributeValue:
					attributeValue = token;
					state = State.ExpectingAttributeCloser;
				break;
			}
		}

		commit();

		return s;
	}

///.
Element[] removeDuplicates(Element[] input) @safe pure {
	Element[] ret;

	bool[Element] already;
	foreach(e; input) {
		if(e in already) continue;
		already[e] = true;
		ret ~= e;
	}

	return ret;
}

// done with CSS selector handling


// FIXME: use the better parser from html.d
/// This is probably not useful to you unless you're writing a browser or something like that.
/// It represents a *computed* style, like what the browser gives you after applying stylesheets, inline styles, and html attributes.
/// From here, you can start to make a layout engine for the box model and have a css aware browser.
class CssStyle {
	///.
	this(string rule, string content) @safe pure {
		rule = rule.strip();
		content = content.strip();

		if(content.length == 0)
			return;

		originatingRule = rule;
		originatingSpecificity = getSpecificityOfRule(rule); // FIXME: if there's commas, this won't actually work!

		foreach(part; content.split(";")) {
			part = part.strip();
			if(part.length == 0)
				continue;
			auto idx = part.indexOf(":");
			if(idx == -1)
				continue;
				//throw new Exception("Bad css rule (no colon): " ~ part);

			Property p;

			p.name = part[0 .. idx].strip();
			p.value = part[idx + 1 .. $].replace("! important", "!important").replace("!important", "").strip(); // FIXME don't drop important
			p.givenExplicitly = true;
			p.specificity = originatingSpecificity;

			properties ~= p;
		}

		foreach(property; properties)
			expandShortForm(property, originatingSpecificity);
	}

	///.
	Specificity getSpecificityOfRule(string rule) @safe pure {
		Specificity s;
		if(rule.length == 0) { // inline
		//	s.important = 2;
		} else {
			// FIXME
		}

		return s;
	}

	string originatingRule; ///.
	Specificity originatingSpecificity; ///.

	///.
	static union Specificity {
		uint score; ///.
		///.
		struct {
			ubyte tags; ///.
			ubyte classes; ///.
			ubyte ids; ///.
			ubyte important; /// 0 = none, 1 = stylesheet author, 2 = inline style, 3 = user important
		}
	}

	///.
	static struct Property {
		bool givenExplicitly; /// this is false if for example the user said "padding" and this is "padding-left"
		string name; ///.
		string value; ///.
		Specificity specificity; ///.
		// do we care about the original source rule?
	}

	///.
	Property[] properties;

	///.
	string opDispatch(string nameGiven)(string value = null) if(nameGiven != "popFront") {
		string name = unCamelCase(nameGiven);
		if(value is null)
			return getValue(name);
		else
			return setValue(name, value, 0x02000000 /* inline specificity */);
	}

	/// takes dash style name
	string getValue(string name) @safe pure {
		foreach(property; properties)
			if(property.name == name)
				return property.value;
		return null;
	}

	/// takes dash style name
	string setValue(string name, string value, Specificity newSpecificity, bool explicit = true) @safe pure {
		value = value.replace("! important", "!important");
		if(value.indexOf("!important") != -1) {
			newSpecificity.important = 1; // FIXME
			value = value.replace("!important", "").strip();
		}

		foreach(ref property; properties)
			if(property.name == name) {
				if(newSpecificity.score >= property.specificity.score) {
					property.givenExplicitly = explicit;
					expandShortForm(property, newSpecificity);
					return (property.value = value);
				} else {
					if(name == "display")
					{}//writeln("Not setting ", name, " to ", value, " because ", newSpecificity.score, " < ", property.specificity.score);
					return value; // do nothing - the specificity is too low
				}
			}

		// it's not here...

		Property p;
		p.givenExplicitly = true;
		p.name = name;
		p.value = value;
		p.specificity = originatingSpecificity;

		properties ~= p;
		expandShortForm(p, originatingSpecificity);

		return value;
	}

	private void expandQuadShort(string name, string value, Specificity specificity) @safe pure {
		auto parts = value.split(" ");
		switch(parts.length) {
			case 1:
				setValue(name ~"-left", parts[0], specificity, false);
				setValue(name ~"-right", parts[0], specificity, false);
				setValue(name ~"-top", parts[0], specificity, false);
				setValue(name ~"-bottom", parts[0], specificity, false);
			break;
			case 2:
				setValue(name ~"-left", parts[1], specificity, false);
				setValue(name ~"-right", parts[1], specificity, false);
				setValue(name ~"-top", parts[0], specificity, false);
				setValue(name ~"-bottom", parts[0], specificity, false);
			break;
			case 3:
				setValue(name ~"-top", parts[0], specificity, false);
				setValue(name ~"-right", parts[1], specificity, false);
				setValue(name ~"-bottom", parts[2], specificity, false);
				setValue(name ~"-left", parts[2], specificity, false);

			break;
			case 4:
				setValue(name ~"-top", parts[0], specificity, false);
				setValue(name ~"-right", parts[1], specificity, false);
				setValue(name ~"-bottom", parts[2], specificity, false);
				setValue(name ~"-left", parts[3], specificity, false);
			break;
			default:
				assert(0, value);
		}
	}

	///.
	void expandShortForm(Property p, Specificity specificity) @safe pure {
		switch(p.name) {
			case "margin":
			case "padding":
				expandQuadShort(p.name, p.value, specificity);
			break;
			case "border":
			case "outline":
				setValue(p.name ~ "-left", p.value, specificity, false);
				setValue(p.name ~ "-right", p.value, specificity, false);
				setValue(p.name ~ "-top", p.value, specificity, false);
				setValue(p.name ~ "-bottom", p.value, specificity, false);
			break;

			case "border-top":
			case "border-bottom":
			case "border-left":
			case "border-right":
			case "outline-top":
			case "outline-bottom":
			case "outline-left":
			case "outline-right":

			default: {}
		}
	}

	///.
	override string toString() @safe pure {
		string ret;
		if(originatingRule.length)
			ret = originatingRule ~ " {";

		foreach(property; properties) {
			if(!property.givenExplicitly)
				continue; // skip the inferred shit

			if(originatingRule.length)
				ret ~= "\n\t";
			else
				ret ~= " ";

			ret ~= property.name ~ ": " ~ property.value ~ ";";
		}

		if(originatingRule.length)
			ret ~= "\n}\n";

		return ret;
	}
}

string cssUrl(string url) @safe pure {
	return "url(\"" ~ url ~ "\")";
}

/// This is kinda private; just a little utility container for use by the ElementStream class.
final class Stack(T) {
	this() {
		internalLength = 0;
		arr = initialBuffer[];
	}

	///.
	void push(T t) {
		if(internalLength >= arr.length) {
			auto oldarr = arr;
			if(arr.length < 4096)
				arr = new T[arr.length * 2];
			else
				arr = new T[arr.length + 4096];
			arr[0 .. oldarr.length] = oldarr[];
		}

		arr[internalLength] = t;
		internalLength++;
	}

	///.
	T pop() {
		assert(internalLength);
		internalLength--;
		return arr[internalLength];
	}

	///.
	T peek() {
		assert(internalLength);
		return arr[internalLength - 1];
	}

	///.
	@property bool empty() {
		return internalLength ? false : true;
	}

	///.
	private T[] arr;
	private size_t internalLength;
	private T[64] initialBuffer;
	// the static array is allocated with this object, so if we have a small stack (which we prolly do; dom trees usually aren't insanely deep),
	// using this saves us a bunch of trips to the GC. In my last profiling, I got about a 50x improvement in the push()
	// function thanks to this, and push() was actually one of the slowest individual functions in the code!
}

/// This is the lazy range that walks the tree for you. It tries to go in the lexical order of the source: node, then children from first to last, each recursively.
final class ElementStream {

	///.
	@property Element front() @safe pure {
		return current.element;
	}

	/// Use Element.tree instead.
	this(Element start) @safe pure {
		current.element = start;
		current.childPosition = -1;
		isEmpty = false;
		stack = new Stack!(Current);
	}

	/*
		Handle it
		handle its children

	*/

	///.
	void popFront() @safe pure {
	    more:
	    	if(isEmpty) return;

		// FIXME: the profiler says this function is somewhat slow (noticeable because it can be called a lot of times)

		current.childPosition++;
		if(current.childPosition >= current.element.children.length) {
			if(stack.empty())
				isEmpty = true;
			else {
				current = stack.pop();
				goto more;
			}
		} else {
			stack.push(current);
			current.element = current.element.children[current.childPosition];
			current.childPosition = -1;
		}
	}

	/// You should call this when you remove an element from the tree. It then doesn't recurse into that node and adjusts the current position, keeping the range stable.
	void currentKilled() @safe pure {
		if(stack.empty) // should never happen
			isEmpty = true;
		else {
			current = stack.pop();
			current.childPosition--; // when it is killed, the parent is brought back a lil so when we popFront, this is then right
		}
	}

	///.
	@property bool empty() @safe pure {
		return isEmpty;
	}

	private:

	static struct Current {
		Element element;
		int childPosition;
	}

	Current current;

	Stack!(Current) stack;

	bool isEmpty;
}



// unbelievable.
// Don't use any of these in your own code. Instead, try to use phobos or roll your own, as I might kill these at any time.
sizediff_t indexOfBytes(immutable(ubyte)[] haystack, immutable(ubyte)[] needle) @safe pure {
	auto found = std.algorithm.searching.find(haystack, needle);
	if(found.length == 0)
		return -1;
	return haystack.length - found.length;
}

private T[] insertAfter(T)(T[] arr, int position, T[] what) {
	assert(position < arr.length);
	T[] ret;
	ret.length = arr.length + what.length;
	int a = 0;
	foreach(i; arr[0..position+1])
		ret[a++] = i;

	foreach(i; what)
		ret[a++] = i;

	foreach(i; arr[position+1..$])
		ret[a++] = i;

	return ret;
}

package bool isInArray(T)(T item, T[] arr) {
	foreach(i; arr)
		if(item == i)
			return true;
	return false;
}

private string[string] aadup(in string[string] arr) @safe pure {
	string[string] ret;
	foreach(k, v; arr)
		ret[k] = v;
	return ret;
}

struct FormFieldOptions {
	// usable for any

	/// this is a regex pattern used to validate the field
	string pattern;
	/// must the field be filled in? Even with a regex, it can be submitted blank if this is false.
	bool isRequired;
	/// this is displayed as an example to the user
	string placeholder;

	// usable for numeric ones


	// convenience methods to quickly get some options
	@property static FormFieldOptions none() @safe pure {
		FormFieldOptions f;
		return f;
	}

	static FormFieldOptions required() @safe pure {
		FormFieldOptions f;
		f.isRequired = true;
		return f;
	}

	static FormFieldOptions regex(string pattern, bool required = false) @safe pure {
		FormFieldOptions f;
		f.pattern = pattern;
		f.isRequired = required;
		return f;
	}

	static FormFieldOptions fromElement(Element e) @safe pure {
		FormFieldOptions f;
		if(e.hasAttribute("required"))
			f.isRequired = true;
		if(e.hasAttribute("pattern"))
			f.pattern = e.getAttribute("pattern");
		if(e.hasAttribute("placeholder"))
			f.placeholder = e.getAttribute("placeholder");
		return f;
	}

	Element applyToElement(Element e) @safe pure {
		if(this.isRequired)
			e.setAttribute("required", "required");
		if(this.pattern.length)
			e.setAttribute("pattern", this.pattern);
		if(this.placeholder.length)
			e.setAttribute("placeholder", this.placeholder);
		return e;
	}
}

// this needs to look just like a string, but can expand as needed
class Utf8Stream {
	protected:
		// these two should be overridden in subclasses to actually do the stream magic
		string getMore() @safe pure {
			if(getMoreHelper !is null)
				return getMoreHelper();
			return null;
		}

		bool hasMore() @safe pure {
			if(hasMoreHelper !is null)
				return hasMoreHelper();
			return false;
		}
		// the rest should be ok

	public:
		this(string d) @safe pure {
			this.data = d;
		}

		this(string delegate() @safe pure getMoreHelper, bool delegate() @safe pure hasMoreHelper) @safe pure {
			this.getMoreHelper = getMoreHelper;
			this.hasMoreHelper = hasMoreHelper;

			if(hasMore())
				this.data ~= getMore();

			// stdout.flush();
		}

		@property final size_t length() @safe pure {
			// the parser checks length primarily directly before accessing the next character
			// so this is the place we'll hook to append more if possible and needed.
			if(lastIdx + 1 >= data.length && hasMore()) {
				data ~= getMore();
			}
			return data.length;
		}

		final char opIndex(size_t idx) @safe pure {
			if(idx > lastIdx)
				lastIdx = idx;
			return data[idx];
		}

		final string opSlice(size_t start, size_t end) @safe pure {
			if(end > lastIdx)
				lastIdx = end;
			return data[start .. end];
		}

		final size_t opDollar() @safe pure {
			return length();
		}

		final Utf8Stream opBinary(string op : "~")(string s) {
			this.data ~= s;
			return this;
		}

		final Utf8Stream opOpAssign(string op : "~")(string s) {
			this.data ~= s;
			return this;
		}

		final Utf8Stream opAssign(string rhs) @safe pure {
			this.data = rhs;
			return this;
		}
	private:
		string data;

		size_t lastIdx;

		bool delegate() @safe pure hasMoreHelper;
		string delegate() @safe pure getMoreHelper;


		/+
		// used to maybe clear some old stuff
		// you might have to remove elements parsed with it too since they can hold slices into the
		// old stuff, preventing gc
		void dropFront(int bytes) {
			posAdjustment += bytes;
			data = data[bytes .. $];
		}

		int posAdjustment;
		+/
}

/++
	Normalizes the whitespace in the given text according to HTML rules.

	History:
		Added March 25, 2022 (dub v10.8)
+/
string normalizeWhitespace(string text) @safe pure {
	string ret;
	ret.reserve(text.length);
	bool lastWasWhite = true;
	foreach(char ch; text) {
		if(ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
			if(lastWasWhite)
				continue;
			lastWasWhite = true;
			ch = ' ';
		} else {
			lastWasWhite = false;
		}

		ret ~= ch;
	}

	return ret.stripRight;
}

@safe pure unittest {
	assert(normalizeWhitespace("    foo   ") == "foo");
	assert(normalizeWhitespace("    f\n \t oo   ") == "f oo");
}

@safe pure unittest {
	Document document;

	document = new Document("<test> foo \r </test>");
	assert(document.root.visibleText == "foo");

	document = new Document("<test> foo \r <br>hi</test>");
	assert(document.root.visibleText == "foo\nhi");

	document = new Document("<test> foo \r <br>hi<pre>hi\nthere\n    indent<br />line</pre></test>");
	assert(document.root.visibleText == "foo\nhihi\nthere\n    indent\nline", document.root.visibleText);
}

/+
/+
Syntax:

Tag: tagname#id.class
Tree: Tag(Children, comma, separated...)
Children: Tee or Variable
Variable: $varname with optional |funcname following.

If a variable has a tree after it, it breaks the variable down:
	* if array, foreach it does the tree
	* if struct, it breaks down the member variables

stolen from georgy on irc, see: https://github.com/georgy7/stringplate
+/
struct Stringplate {
	/++

	+/
	this(string s) {

	}

	/++

	+/
	Element expand(T...)(T vars) {
		return null;
	}
}
///
@safe pure unittest {
	auto stringplate = Stringplate("#bar(.foo($foo), .baz($baz))");
	assert(stringplate.expand.innerHTML == `<div id="bar"><div class="foo">$foo</div><div class="baz">$baz</div></div>`);
}
+/

bool allAreInlineHtml(const(Element)[] children, const string[] inlineElements) @safe pure {
	foreach(child; children) {
		if(child.nodeType == NodeType.Text && child.nodeValue.strip.length) {
			// cool
		} else if(child.tagName.isInArray(inlineElements) && allAreInlineHtml(child.children, inlineElements)) {
			// cool, this is an inline element and none of its children contradict that
		} else {
			// prolly block
			return false;
		}
	}
	return true;
}

private bool isSimpleWhite(dchar c) @safe pure {
	return c == ' ' || c == '\r' || c == '\n' || c == '\t';
}

@safe pure unittest {
	// Test for issue #120
	string s = `<html>
	<body>
		<P>AN
		<P>bubbles</P>
		<P>giggles</P>
	</body>
</html>`;
	auto doc = new Document();
	doc.parseUtf8(s, false, false);
	auto s2 = doc.toString();
	assert(
			s2.indexOf("bubbles") < s2.indexOf("giggles"),
			"paragraph order incorrect:\n" ~ s2);
}

@safe pure unittest {
	// test for suncarpet email dec 24 2019
	// arbitrary id asduiwh
	auto document = new Document("<html>
        <head>
                <meta charset=\"utf-8\"></meta>
                <title>Element.querySelector Test</title>
        </head>
        <body>
                <div id=\"foo\">
                        <div>Foo</div>
                        <div>Bar</div>
                </div>
		<div id=\"empty\"></div>
		<div id=\"empty-but-text\">test</div>
		<div class=\"class\nclass-with-newlines\">test2</div>
        </body>
</html>");

	auto doc = document;

	with(doc.requireElementById("empty")) {
		assert(querySelector(" > *") is null, querySelector(" > *").toString);
	}
	with(doc.requireElementById("empty-but-text")) {
		assert(querySelector(" > *") is null, querySelector(" > *").toString);
	}
	assert(doc.querySelector("div.class-with-newlines") !is null);

	assert(doc.querySelectorAll("div div").length == 2);
	assert(doc.querySelector("div").querySelectorAll("div").length == 2);
	assert(doc.querySelectorAll("> html").length == 0);
	assert(doc.querySelector("head").querySelectorAll("> title").length == 1);
	assert(doc.querySelector("head").querySelectorAll("> meta[charset]").length == 1);


	assert(doc.root.matches("html"));
	assert(!doc.root.matches("nothtml"));
	assert(doc.querySelector("#foo > div").matches("div"));
	assert(doc.querySelector("body > #foo").matches("#foo"));

	assert(doc.root.querySelectorAll(":root > body").length == 0); // the root has no CHILD root!
	assert(doc.querySelectorAll(":root > body").length == 1); // but the DOCUMENT does
	assert(doc.querySelectorAll(" > body").length == 1); //  should mean the same thing
	assert(doc.root.querySelectorAll(" > body").length == 1); // the root of HTML has this
	assert(doc.root.querySelectorAll(" > html").length == 0); // but not this

	// also confirming the querySelector works via the mdn definition
	auto foo = doc.requireSelector("#foo");
	assert(foo.querySelector("#foo > div") !is null);
	assert(foo.querySelector("body #foo > div") !is null);

	// this is SUPPOSED to work according to the spec but never has in dom.d since it limits the scope.
	// the new css :scope thing is designed to bring this in. and meh idk if i even care.
	//assert(foo.querySelectorAll("#foo > div").length == 2);
}

@safe pure unittest {
	// based on https://developer.mozilla.org/en-US/docs/Web/API/Element/closest example
	auto document = new Document(`<article>
  <div id="div-01">Here is div-01
    <div id="div-02">Here is div-02
      <div id="div-03">Here is div-03</div>
    </div>
  </div>
</article>`, true, true);

	auto el = document.getElementById("div-03");
	assert(el.closest("#div-02").getAttribute("id") == "div-02");
	assert(el.closest("div div").getAttribute("id") == "div-03");
	assert(el.closest("article > div").getAttribute("id") == "div-01");
	assert(el.closest(":not(div)").tagName == "article");

	assert(el.closest("p") is null);
	assert(el.closest("p, div") is el);
}

@safe pure unittest {
	// https://developer.mozilla.org/en-US/docs/Web/CSS/:is
	auto document = new Document(`<test>
		<div class="foo"><p>cool</p><span>bar</span></div>
		<main><p>two</p></main>
	</test>`);

	assert(document.querySelectorAll(":is(.foo, main) p").length == 2);
	assert(document.querySelector("div:where(.foo)") !is null);
}

@safe pure unittest {
immutable string html = q{
<root>
<div class="roundedbox">
 <table>
  <caption class="boxheader">Recent Reviews</caption>
  <tr>
   <th>Game</th>
   <th>User</th>
   <th>Rating</th>
   <th>Created</th>
  </tr>

  <tr>
   <td>June 13, 2020 15:10</td>
   <td><a href="/reviews/8833">[Show]</a></td>
  </tr>

  <tr>
   <td>June 13, 2020 15:02</td>
   <td><a href="/reviews/8832">[Show]</a></td>
  </tr>

  <tr>
   <td>June 13, 2020 14:41</td>
   <td><a href="/reviews/8831">[Show]</a></td>
  </tr>
 </table>
</div>
</root>
};

  auto doc = new Document(cast(string)html);
  // this should select the second table row, but...
  auto rd = doc.root.querySelector(`div.roundedbox > table > caption.boxheader + tr + tr + tr > td > a[href^=/reviews/]`);
  assert(rd !is null);
  assert(rd.getAttribute("href") == "/reviews/8832");

  rd = doc.querySelector(`div.roundedbox > table > caption.boxheader + tr + tr + tr > td > a[href^=/reviews/]`);
  assert(rd !is null);
  assert(rd.getAttribute("href") == "/reviews/8832");
}

@safe pure unittest {
	try {
		auto doc = new XmlDocument("<testxmlns:foo=\"/\"></test>");
		assert(0);
	} catch(Exception e) {
		// good; it should throw an exception, not an error.
	}
}

@safe pure unittest {
	// toPrettyString is not stable, but these are some best-effort attempts
	// despite these being in a test, I might change these anyway!
	assert(Element.make("a").toPrettyString == "<a></a>");
	assert(Element.make("a", "").toPrettyString(false, 0, " ") == "<a></a>");
	assert(Element.make("a", " ").toPrettyString(false, 0, " ") == "<a> </a>");//, Element.make("a", " ").toPrettyString(false, 0, " "));
	assert(Element.make("a", "b").toPrettyString == "<a>b</a>");
	assert(Element.make("a", "b").toPrettyString(false, 0, "") == "<a>b</a>");

	{
	auto document = new Document("<html><body><p>hello <a href=\"world\">world</a></p></body></html>");
	auto pretty = document.toPrettyString(false, 0, "  ");
	assert(pretty ==
`<!DOCTYPE html>
<html>
  <body>
    <p>hello <a href="world">world</a></p>
  </body>
</html>`, pretty);
	}

	{
	auto document = new XmlDocument("<html><body><p>hello <a href=\"world\">world</a></p></body></html>");
	assert(document.toPrettyString(false, 0, "  ") ==
`<?xml version="1.0" encoding="UTF-8"?>
<html>
  <body>
    <p>
      hello
      <a href="world">world</a>
    </p>
  </body>
</html>`);
	}

	foreach(test; [
		"<a att=\"http://ele\"><b><ele1>Hello</ele1>\n  <c>\n   <d>\n    <ele2>How are you?</ele2>\n   </d>\n   <e>\n    <ele3>Good &amp; you?</ele3>\n   </e>\n  </c>\n </b>\n</a>",
		"<a att=\"http://ele\"><b><ele1>Hello</ele1><c><d><ele2>How are you?</ele2></d><e><ele3>Good &amp; you?</ele3></e></c></b></a>",
	] )
	{
	auto document = new XmlDocument(test);
	assert(document.root.toPrettyString(false, 0, " ") == "<a att=\"http://ele\">\n <b>\n  <ele1>Hello</ele1>\n  <c>\n   <d>\n    <ele2>How are you?</ele2>\n   </d>\n   <e>\n    <ele3>Good &amp; you?</ele3>\n   </e>\n  </c>\n </b>\n</a>");
	assert(document.toPrettyString(false, 0, " ") == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a att=\"http://ele\">\n <b>\n  <ele1>Hello</ele1>\n  <c>\n   <d>\n    <ele2>How are you?</ele2>\n   </d>\n   <e>\n    <ele3>Good &amp; you?</ele3>\n   </e>\n  </c>\n </b>\n</a>");
	auto omg = document.root;
	omg.parent_ = null;
	assert(omg.toPrettyString(false, 0, " ") == "<a att=\"http://ele\">\n <b>\n  <ele1>Hello</ele1>\n  <c>\n   <d>\n    <ele2>How are you?</ele2>\n   </d>\n   <e>\n    <ele3>Good &amp; you?</ele3>\n   </e>\n  </c>\n </b>\n</a>");
	}

	{
	auto document = new XmlDocument(`<a><b>toto</b><c></c></a>`);
	assert(document.root.toPrettyString(false, 0, null) == `<a><b>toto</b><c></c></a>`);
	assert(document.root.toPrettyString(false, 0, " ") == `<a>
 <b>toto</b>
 <c></c>
</a>`);
	}

	{
auto str = `<!DOCTYPE html>
<html>
	<head>
		<title>Test</title>
	</head>
	<body>
		<p>Hello there</p>
		<p>I like <a href="">Links</a></p>
		<div>
			this is indented since there's a block inside
			<p>this is the block</p>
			and this gets its own line
		</div>
	</body>
</html>`;
		auto doc = new Document(str, true, true);
		assert(doc.toPrettyString == str);
	}
}

@safe pure unittest {
	auto document = new Document("<foo><items><item><title>test</title><desc>desc</desc></item></items></foo>");
	auto items = document.root.requireSelector("> items");
	auto item = items.requireSelector("> item");
	auto title = item.requireSelector("> title");

	// this not actually implemented at this point but i might want to later. it prolly should work as an extension of the standard behavior
	// assert(title.requireSelector("~ desc").innerText == "desc");

	assert(item.requireSelector("title ~ desc").innerText == "desc");

	assert(items.querySelector("item:has(title)") !is null);
	assert(items.querySelector("item:has(nothing)") is null);

	assert(title.innerText == "test");
}

@safe pure unittest {
	auto document = new Document("broken"); // just ensuring it doesn't crash
}
