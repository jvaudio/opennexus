// Safari web clipper (Settings › Integrations): hands the page's title, address,
// selection and readable text to the Share extension. Runs only when the user shares
// the page to OpenNexus; nothing is sent anywhere else.
var ClipPage = function () {};
ClipPage.prototype = {
    run: function (args) {
        var selection = window.getSelection ? String(window.getSelection()) : "";
        var main = document.querySelector("article") || document.querySelector("main") || document.body;
        var text = main ? main.innerText : "";
        args.completionFunction({
            title: document.title,
            url: document.URL,
            selection: selection,
            text: text.slice(0, 20000)
        });
    },
    finalize: function (args) {}
};
var ExtensionPreprocessingJS = new ClipPage();
