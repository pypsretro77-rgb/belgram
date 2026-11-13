import Foundation
import UIKit
import WebKit

final class VisualGiftScreen: UIViewController {
    private let slug: String
    private let webView = WKWebView()
    private let activityIndicator = UIActivityIndicatorView(style: .large)

    init(slug: String = "plushpepe-1") {
        self.slug = slug
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor.black.withAlphaComponent(0.85)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        
        self.view.addSubview(webView)
        
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        activityIndicator.startAnimating()
        self.view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            webView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            webView.heightAnchor.constraint(equalToConstant: 480),
            
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        loadGiftData()
    }

    private func loadGiftData() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <script src="https://cdnjs.cloudflare.com/ajax/libs/bodymovin/5.12.2/lottie.min.js"></script>
            <style>
                body { margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; height: 100vh; font-family: -apple-system, sans-serif; }
                #card { width: 100%; height: 100%; border-radius: 30px; position: relative; overflow: hidden; display: flex; flex-direction: column; align-items: center; box-shadow: 0 10px 30px rgba(0,0,0,0.5); background: #2C2C2E; }
                #anim { width: 280px; height: 280px; margin-top: 30px; z-index: 2; }
                .text-container { z-index: 2; text-align: center; color: white; margin-top: 10px; }
                .title { font-size: 24px; font-weight: bold; margin-bottom: 5px; text-shadow: 0 2px 4px rgba(0,0,0,0.5); }
                .subtitle { font-size: 16px; opacity: 0.8; text-shadow: 0 1px 2px rgba(0,0,0,0.5); }
                #number { position: absolute; top: 20px; right: 20px; font-size: 20px; font-weight: bold; color: rgba(255,255,255,0.7); z-index: 2; }
                #attributes { z-index: 2; margin-top: 20px; background: rgba(0,0,0,0.4); padding: 10px 20px; border-radius: 15px; color: white; font-size: 14px; text-align: center; }
            </style>
        </head>
        <body>
            <div id="card">
                <div id="number">#---</div>
                <div id="anim"></div>
                <div class="text-container">
                    <div class="title" id="title">Загрузка...</div>
                    <div class="subtitle" id="subtitle"></div>
                </div>
                <div id="attributes"></div>
            </div>
            <script>
                const slug = "\(slug)";
                fetch(`https://nft.fragment.com/gift/${slug}.json`)
                    .then(res => res.json())
                    .then(data => {
                        let model = "Unknown", backdrop = "Unknown", symbol = "Unknown";
                        if (data.attributes) {
                            data.attributes.forEach(attr => {
                                if (attr.trait_type === "Model") model = attr.value;
                                if (attr.trait_type === "Backdrop") backdrop = attr.value;
                                if (attr.trait_type === "Symbol") symbol = attr.value;
                            });
                        }
                        document.getElementById('title').innerText = data.name || "Gift";
                        document.getElementById('subtitle').innerText = model;
                        document.getElementById('attributes').innerHTML = `Фон: <b>${backdrop}</b><br>Значок: <b>${symbol}</b>`;
                        
                        const num = slug.split('-').pop();
                        document.getElementById('number').innerText = "#" + num.padStart(5, '0');

                        let bgColor = "#2C2C2E";
                        if (backdrop.includes("Aquamarine")) bgColor = "#2E8B57";
                        if (backdrop.includes("Black")) bgColor = "#111";
                        if (backdrop.includes("Onyx")) bgColor = "#1a1a1a";
                        if (backdrop.includes("Gold")) bgColor = "#D4AF37";
                        if (backdrop.includes("Crimson")) bgColor = "#8B0000";
                        if (backdrop.includes("Ocean")) bgColor = "#000080";
                        document.getElementById('card').style.background = bgColor;

                        lottie.loadAnimation({
                            container: document.getElementById('anim'),
                            renderer: 'svg',
                            loop: true,
                            autoplay: true,
                            path: `https://nft.fragment.com/gift/${slug}.lottie.json`
                        });
                    })
                    .catch(err => {
                        document.getElementById('title').innerText = "Ошибка";
                        document.getElementById('subtitle').innerText = "Подарок не найден";
                    });
            </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://nft.fragment.com"))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.activityIndicator.stopAnimating()
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.dismiss(animated: true, completion: nil)
    }
}
