import Foundation

struct AnnotationPrompt: Identifiable, Hashable {
    let id: String
    let title: String
    let instructions: String

    static let closeReading = AnnotationPrompt(id: "close", title: "通用精读", instructions: """
    帮我读懂作者的论证。选出最能串起研究问题、关键方法、主要发现和适用边界的原文。若摘要和正文重复，优先选能交代证据或限定条件的那一处。
    在每条 note 里说明这段话在论证中起什么作用，以及它和前后哪一步有关。若论文以理论推导为主，可沿着问题、假设、推导和结论来选段。
    """)

    static let choices = [
        closeReading,
        AnnotationPrompt(id: "skim", title: "快速初读", instructions: """
        帮我判断这篇论文是否值得通读。通常选 2 至 4 处，让我能回答三个问题：作者想解决什么、最值得记住的发现是什么、谁可能用得上这个发现？若有直接影响判断的适用条件，一并选出。
        每条 note 用一句通俗中文概括这一处对初读判断的帮助。若要继续读，指向一个能在本文中找到的具体章节或图表，并说清去那里看什么。
        """),
        AnnotationPrompt(id: "method", title: "方法评读", instructions: """
        帮我判断研究方法能否回答作者提出的问题。选择会改变判断的设计细节，例如研究对象如何选取、关键概念如何测量、比较基准如何设定，或理论推导依赖什么假设。
        每条 note 解释该选择对结果解释的影响。对设计上的疑问，写成读者需要核实的具体问题。原文没有交代的信息请标为“文中未说明”。
        """),
        AnnotationPrompt(id: "evidence", title: "证据核查", instructions: """
        帮我核查最重要的一两项结论。分别摘录作者提出主张的句子和直接支持它的结果；主张与证据不相邻时分为两条批注，在 note 里写明它们核查的是哪一项结论。
        在结果的 note 中说明实际观察到了什么、这些证据能支持多强的判断。若原文提供了对照组、效应大小或不确定性，保留解释结果所必需的信息；标清哪些说法是作者的解释。
        """),
        AnnotationPrompt(id: "review", title: "综述对比", instructions: """
        帮我为文献综述积累可横向比较的材料。本次只分析随附的这一篇。优先选出能说明研究对象、比较条件、评价指标、时间范围和结论边界的引文。
        每条 note 指明一个比较维度，再写一句保留了适用条件、可以放进综述草稿的中文表述。注明所述发现来自本研究还是作者转述的既有文献。若要与其他研究比较，指出对方需要报告哪项信息才能对照。
        """),
        AnnotationPrompt(id: "terms", title: "术语译读", instructions: """
        帮我掌握影响理解的术语和句子。优先选择作者下定义、区分近义概念，或用否定、程度和范围限定论断的完整语句。选段应提供足够上下文来判断词义。
        translation 写成自然、准确的中文，重要术语首次出现时在括号里保留原词。在 note 里解释该词在本文特指什么，或指出哪一个限定词会改变整句的理解。kind 仍按这句话在论文里的作用选择。
        """)
    ]

    func text(documentHash: String?) -> String {
        let fingerprintLine = documentHash.map { "  \"document_sha256\": \"\($0)\",\n" } ?? ""
        let fingerprintRule = documentHash == nil ? "" : "\n保留下方给定的 document_sha256，它对应当前 PDF。"
        let prefix = "jd-\(id)-"
        return """
        请阅读随附的论文 PDF，按“\(title)”的目的，为中文读者制作可定位到原文的快读论文批注。

        \(instructions)

        每条 quote 逐字摘录同一页内的连续原文，保留原文语言和标点。page 是从 1 开始的 PDF 物理页码，封面计入；不能确定时省略 page。若同一句在该页重复，附上紧邻引文的原文 prefix 或 suffix 以便区分。
        translation 填写忠实的中文翻译，保留数值、否定和限定条件。note 填写本次阅读目的所需的中文注解。kind 取 claim（观点）、method（方法）、finding（发现）或 limitation（局限）。
        公式在 translation 或 note 中可使用 LaTeX，行内用 $...$，独立公式用 $$...$$；输出 JSON 时须将每个反斜杠转义为两个反斜杠。quote 采用 PDF 中实际可复制的原文，不把原式改写为 LaTeX。若公式是图片或包含无法判读的字形，摘录同页紧邻公式的一句可核对原文，并在 note 写明公式编号或位置和需要人工核对的符号。
        每条 id 以 \(prefix) 开头，后接能辨认这处引文的短名称，确保在本篇文献内唯一。修订已有批注时沿用它的完整 id。所有引文和确切事实都要能回到随附 PDF 核实。\(fingerprintRule)

        只输出一个 UTF-8 JSON 对象。参照以下结构，将示例条目替换为实际批注：
        {
          "schema_version": 1,
        \(fingerprintLine)  "annotations": [
            {
              "id": "\(prefix)example-passage",
              "page": 1,
              "kind": "claim",
              "quote": "替换为连续原文",
              "translation": "替换为中文译文",
              "note": "替换为针对本次阅读目的的注解"
            }
          ]
        }
        """
    }
}
