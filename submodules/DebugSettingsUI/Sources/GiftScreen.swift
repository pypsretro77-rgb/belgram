import Foundation
import UIKit

private final class GradientView: UIView {
    override class var layerClass: AnyClass {
        return CAGradientLayer.self
    }
}

final class GiftScreen: UIViewController {
    private let senderName = "transaction.from"
    private let giftName = "Myth Mask"
    private let giftNumber = "#00001"
    private let modelName = "Wooden Smile"
    private let backdropName = "Black"
    private let symbolName = "French Fries"
    private let uniqueGiftSlug = "plushpepe-1"

    init() {
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .black

        let background = GradientView()
        background.translatesAutoresizingMaskIntoConstraints = false
        if let gradient = background.layer as? CAGradientLayer {
            gradient.colors = [
                UIColor(red: 0.98, green: 0.20, blue: 0.45, alpha: 1.0).cgColor,
                UIColor(red: 1.00, green: 0.70, blue: 0.10, alpha: 1.0).cgColor
            ]
            gradient.startPoint = CGPoint(x: 0.0, y: 0.0)
            gradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        }
        self.view.addSubview(background)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: self.view.topAnchor),
            background.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: self.view.trailingAnchor)
        ])

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Закрыть", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.view.addSubview(closeButton)

        let footer = UILabel()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = UIFont.systemFont(ofSize: 12.0, weight: .semibold)
        footer.textColor = UIColor.white.withAlphaComponent(0.9)
        footer.textAlignment = .center
        self.view.addSubview(footer)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14.0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(stack)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 8.0),
            closeButton.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 16.0),
            footer.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -12.0),
            stack.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20.0),
            stack.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20.0),
            stack.centerYAnchor.constraint(equalTo: self.view.centerYAnchor)
        ])

        let first = self.makeIncomingRow(text: "ок")
        let second = self.makeIncomingRow(text: "держи")
        stack.addArrangedSubview(first)
        stack.addArrangedSubview(second)
        first.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        second.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(self.makeSystemPill(text: "\(self.senderName) передал(а) Вам уникальный коллекционный подарок"))

        let card = self.makeCard()
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalToConstant: 270.0).isActive = true
    }

    @objc private func closePressed() {
        self.dismiss(animated: true, completion: nil)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }

    private func makeIncomingRow(text: String) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let bubble = UIView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        bubble.layer.cornerRadius = 18.0
        let label = self.makeLabel(text, size: 20.0, weight: .semibold, color: .black)
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14.0),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14.0),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8.0),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8.0),
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor)
        ])
        return row
    }

    private func makeSystemPill(text: String) -> UIView {
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        pill.layer.cornerRadius = 16.0
        let label = self.makeLabel(text, size: 14.0, weight: .semibold, color: .white)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = 290.0
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14.0),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14.0),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8.0),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8.0)
        ])
        return pill
    }

    private func makeAttributeRow(title: String, value: String) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12.0
        row.alignment = .firstBaseline
        row.addArrangedSubview(self.makeLabel(title, size: 16.0, weight: .regular, color: UIColor(white: 0.6, alpha: 1.0)))
        row.addArrangedSubview(self.makeLabel(value, size: 16.0, weight: .bold, color: .white))
        return row
    }

    private func makeCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
        card.layer.cornerRadius = 28.0
        card.clipsToBounds = true

        let content = UIStackView()
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 6.0
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)

             let animationView = GiftLottieView()
     animationView.translatesAutoresizingMaskIntoConstraints = false
     content.addArrangedSubview(animationView)
     NSLayoutConstraint.activate([
         animationView.widthAnchor.constraint(equalToConstant: 200.0),
         animationView.heightAnchor.constraint(equalToConstant: 200.0)
     ])
     animationView.load(slug: self.uniqueGiftSlug)
     content.setCustomSpacing(14.0, after: animationView)

        content.addArrangedSubview(self.makeLabel("Подарок от \(self.senderName)", size: 20.0, weight: .bold, color: .white))
        let subtitle = self.makeLabel("\(self.giftName) \(self.giftNumber)", size: 17.0, weight: .regular, color: UIColor(white: 0.7, alpha: 1.0))
        content.addArrangedSubview(subtitle)
        content.setCustomSpacing(16.0, after: subtitle)

        let rows = UIStackView()
        rows.axis = .vertical
        rows.alignment = .center
        rows.spacing = 8.0
        rows.addArrangedSubview(self.makeAttributeRow(title: "Модель", value: self.modelName))
        rows.addArrangedSubview(self.makeAttributeRow(title: "Фон", value: self.backdropName))
        rows.addArrangedSubview(self.makeAttributeRow(title: "Значок", value: self.symbolName))
        content.addArrangedSubview(rows)
        content.setCustomSpacing(18.0, after: rows)

        content.addArrangedSubview(self.makeLabel("Посмотреть", size: 20.0, weight: .semibold, color: .white))

        let ribbon = UILabel()
        ribbon.translatesAutoresizingMaskIntoConstraints = false
        ribbon.text = "Подарок"
        ribbon.textAlignment = .center
        ribbon.font = UIFont.systemFont(ofSize: 12.0, weight: .heavy)
        ribbon.textColor = .white
        ribbon.backgroundColor = UIColor(red: 0.85, green: 0.20, blue: 0.20, alpha: 1.0)
        card.addSubview(ribbon)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16.0),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16.0),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 28.0),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24.0),
            ribbon.widthAnchor.constraint(equalToConstant: 120.0),
            ribbon.heightAnchor.constraint(equalToConstant: 22.0),
            ribbon.centerXAnchor.constraint(equalTo: card.trailingAnchor, constant: -30.0),
            ribbon.centerYAnchor.constraint(equalTo: card.topAnchor, constant: 30.0)
        ])
        ribbon.transform = CGAffineTransform(rotationAngle: CGFloat.pi / 4.0)
        return card
    }
}
