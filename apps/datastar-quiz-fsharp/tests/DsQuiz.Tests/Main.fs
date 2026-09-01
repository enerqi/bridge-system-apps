module DsQuiz.Tests.Main

open Expecto

[<EntryPoint>]
let main (argv: string array) : int =
    runTestsWithCLIArgs
        []
        argv
        (testList
            "dsquiz"
            [ BidsTests.tests
              CorpusTests.tests
              EngineTests.tests
              NamesTests.tests
              RenderTests.tests
              ViewsTests.tests ])
