const content = document.getElementById("content");
function reportHeight() {
    window.webkit.messageHandlers.height.postMessage(content.getBoundingClientRect().height);
}
new ResizeObserver(reportHeight).observe(content);

function draw(parts, size, quote, dark) {
    content.classList.toggle("dark", dark);
    content.classList.toggle("quote", quote);
    content.style.fontSize = size + "px";
    const fragment = document.createDocumentFragment();
    let hasUnrenderedFormula = false;
    for (const part of parts) {
        if ("text" in part) {
            fragment.append(document.createTextNode(part.text));
            continue;
        }
        const span = document.createElement("span");
        try {
            if (part.math.length > 12000) throw new Error();
            const display = part.style === "block";
            // The annotation is passed as data. Only the local math renderer creates markup.
            span.innerHTML = katex.renderToString(part.math, {
                output: "mathml", displayMode: display, trust: false, throwOnError: true, maxExpand: 500, maxSize: 20
            });
            span.className = display ? "math-block" : "math-inline";
        } catch {
            span.textContent = part.raw;
            span.className = "literal";
            hasUnrenderedFormula = true;
        }
        fragment.append(span);
    }
    if (hasUnrenderedFormula) {
        const hint = document.createElement("small");
        hint.textContent = "部分公式已显示为原始写法";
        fragment.append(hint);
    }
    content.replaceChildren(fragment);
    reportHeight();
}
