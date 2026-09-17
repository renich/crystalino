require "../support/unwrap"
require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"

class LSP::Server
  def self.read_for_test(io : IO)
    read(io)
  end
end

describe "JSON-RPC Wire Protocol" do
  it "parses wire framing with Content-Length header" do
    io = IO::Memory.new
    payload = %({"jsonrpc":"2.0","id":42,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///project/src/main.cr"},"position":{"line":10,"character":5}}})
    io.print "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
    io.rewind

    msg = LSP::Server.read_for_test(io)
    msg.is_a?(LSP::DocumentHighlightRequest).should be_true
    req = msg.as(LSP::DocumentHighlightRequest)
    req.id.should eq(42)
    req.params.text_document.uri.should eq("file:///project/src/main.cr")
    req.params.position.line.should eq(10)
    req.params.position.character.should eq(5)
  end

  it "raises when Content-Length header is missing" do
    io = IO::Memory.new
    payload = %({"jsonrpc":"2.0","id":1,"method":"textDocument/completion","params":{}})
    io.print "Content-Type: application/json\r\n\r\n#{payload}"
    io.rewind

    expect_raises(IO::EOFError) do
      LSP::Server.read_for_test(io)
    end
  end

  it "deserializes extended and standard requests properly" do
    cases = {
      {"workspace/symbol", %({"jsonrpc":"2.0","id":1,"method":"workspace/symbol","params":{"query":"MyClass"}}), LSP::WorkspaceSymbolRequest},
      {"textDocument/documentHighlight", %({"jsonrpc":"2.0","id":2,"method":"textDocument/documentHighlight","params":{"textDocument":{"uri":"file:///a.cr"},"position":{"line":0,"character":0}}}), LSP::DocumentHighlightRequest},
      {"textDocument/foldingRange", %({"jsonrpc":"2.0","id":3,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///a.cr"}}}), LSP::FoldingRangeRequest},
      {"textDocument/selectionRange", %({"jsonrpc":"2.0","id":4,"method":"textDocument/selectionRange","params":{"textDocument":{"uri":"file:///a.cr"},"positions":[{"line":0,"character":0}]}}), LSP::SelectionRangeRequest},
      {"textDocument/signatureHelp", %({"jsonrpc":"2.0","id":5,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///a.cr"},"position":{"line":0,"character":0}}}), LSP::SignatureHelpRequest},
      {"textDocument/completion", %({"jsonrpc":"2.0","id":6,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.cr"},"position":{"line":0,"character":0}}}), LSP::CompletionRequest},
      {"textDocument/hover", %({"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.cr"},"position":{"line":0,"character":0}}}), LSP::HoverRequest},
      {"textDocument/definition", %({"jsonrpc":"2.0","id":8,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///a.cr"},"position":{"line":0,"character":0}}}), LSP::DefinitionRequest},
      {"unknown/customMethod", %({"jsonrpc":"2.0","id":9,"method":"unknown/customMethod","params":{}}), LSP::UnknownRequest},
    }

    cases.each do |(name, json, expected_type)|
      msg = LSP::RequestMessage.from_json(json)
      msg.class.should eq(expected_type), "Failed for #{name}: expected #{expected_type}, got #{msg.class}"
    end
  end

  it "serializes document highlight response correctly" do
    range = LSP::Range.new(
      start: LSP::Position.new(line: 1, character: 2),
      end: LSP::Position.new(line: 1, character: 7)
    )
    highlight = LSP::DocumentHighlight.new(range: range, kind: LSP::DocumentHighlightKind::Write)
    response = LSP::ResponseMessage(Array(LSP::DocumentHighlight)?).new(id: 1, result: [highlight])
    json = response.to_json

    json.should contain(%("kind":3))
    json.should contain(%("start":{"line":1,"character":2}))
    json.should contain(%("end":{"line":1,"character":7}))
  end

  it "serializes folding range response with camelCase keys and string kinds" do
    fold = LSP::FoldingRange.new(
      start_line: 0,
      end_line: 5,
      kind: LSP::FoldingRangeKind::Comment
    )
    response = LSP::ResponseMessage(Array(LSP::FoldingRange)?).new(id: 2, result: [fold])
    json = response.to_json

    json.should contain(%("startLine":0))
    json.should contain(%("endLine":5))
    json.should contain(%("kind":"comment"))
  end

  it "serializes selection range with nested parent hierarchy" do
    outer = LSP::SelectionRange.new(
      range: LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 0),
        end: LSP::Position.new(line: 10, character: 0)
      ),
      parent: nil
    )
    inner = LSP::SelectionRange.new(
      range: LSP::Range.new(
        start: LSP::Position.new(line: 2, character: 4),
        end: LSP::Position.new(line: 2, character: 10)
      ),
      parent: outer
    )
    response = LSP::ResponseMessage(Array(LSP::SelectionRange)?).new(id: 3, result: [inner])
    json = response.to_json

    json.should contain(%("parent":))
    json.should contain(%("line":2,"character":4))
  end
end
