// The trading journey: goods that are cheap where they are produced and dearer the farther they travel,
// money, what the walker carries, and how they get around. No fighting anywhere.
import Foundation

struct Good {
    let name: String
    let base: Int
    let home: String   // country where it is produced
}

struct Transport {
    let name: String
    let walk: Float    // metres per second
    let run: Float
    let capacity: Int
    let cost: Int
}

enum Economy {
    static let goods: [Good] = [
        Good(name: "Rooibos tea", base: 20, home: "South Africa"), Good(name: "Wool", base: 35, home: "South Africa"),
        Good(name: "Baskets", base: 40, home: "Botswana"), Good(name: "Biltong", base: 30, home: "Botswana"),
        Good(name: "Soapstone carving", base: 60, home: "Zimbabwe"), Good(name: "Copper wire", base: 80, home: "Zambia"),
        Good(name: "Kitenge cloth", base: 45, home: "Tanzania"), Good(name: "Cloves", base: 70, home: "Tanzania"),
        Good(name: "Tea", base: 25, home: "Kenya"), Good(name: "Beadwork", base: 55, home: "Kenya"),
        Good(name: "Coffee", base: 50, home: "Ethiopia"), Good(name: "Honey", base: 40, home: "Ethiopia"),
        Good(name: "Gum arabic", base: 60, home: "Sudan"), Good(name: "Hibiscus", base: 30, home: "Sudan"),
        Good(name: "Cotton", base: 35, home: "Egypt"), Good(name: "Papyrus", base: 65, home: "Egypt"),
    ]

    static let transports: [Transport] = [
        Transport(name: "On foot", walk: 1.7, run: 5.4, capacity: 6, cost: 0),
        Transport(name: "Bicycle", walk: 4.5, run: 8, capacity: 12, cost: 300),
        Transport(name: "Motorbike", walk: 9, run: 16, capacity: 20, cost: 1500),
        Transport(name: "Land Cruiser", walk: 13, run: 24, capacity: 60, cost: 6000),
    ]

    static let traderNames: [String: String] = [
        "South Africa": "Thandi", "Botswana": "Kagiso", "Zimbabwe": "Tendai", "Zambia": "Mwila", "Tanzania": "Neema",
        "Kenya": "Wanjiru", "Ethiopia": "Abebe", "Sudan": "Amira", "Egypt": "Youssef",
    ]

    // Amboseli's trader is Maasai; elsewhere the name goes by country.
    static func trader(at stage: Int) -> String {
        stage == 11 ? "Naserian" : traderNames[Route.stages[stage].country] ?? "The trader"
    }

    // Price at a stop: 60% of base at home, rising 7% for every stop of distance from the nearest home stop.
    static func price(_ good: Int, at stage: Int) -> Int {
        let g = goods[good]
        let homes = Route.stages.indices.filter { Route.stages[$0].country == g.home }
        let away = homes.map { abs($0 - stage) }.min() ?? 10
        let factor = away == 0 ? 0.6 : min(1 + 0.07 * Double(away), 2.2)
        return max(1, Int((Double(g.base) * factor).rounded()))
    }

    // Six goods on offer: everything local, then the nearest foreign goods.
    static func offer(at stage: Int) -> [Int] {
        let country = Route.stages[stage].country
        let local = goods.indices.filter { goods[$0].home == country }
        let others = goods.indices.filter { goods[$0].home != country }.sorted { (price($0, at: stage), $0) < (price($1, at: stage), $1) }
        return Array((local + others).prefix(6))
    }
}

// The walker's possessions, kept between launches.
final class Journey {
    private(set) var money: Int
    private(set) var cargo: [Int]
    private(set) var transport: Int

    init() {
        let d = UserDefaults.standard
        money = d.object(forKey: "money") as? Int ?? 200
        let saved = d.array(forKey: "cargo") as? [Int] ?? []
        cargo = saved.count == Economy.goods.count ? saved : Array(repeating: 0, count: Economy.goods.count)
        transport = min(max(d.integer(forKey: "transport"), 0), Economy.transports.count - 1)
    }

    var vehicle: Transport { Economy.transports[transport] }
    var carried: Int { cargo.reduce(0, +) }

    private func save() {
        let d = UserDefaults.standard
        d.set(money, forKey: "money")
        d.set(cargo, forKey: "cargo")
        d.set(transport, forKey: "transport")
    }

    func buy(_ good: Int, at stage: Int) -> String {
        let p = Economy.price(good, at: stage)
        if carried >= vehicle.capacity { return "You can't carry any more \(vehicle.name.lowercased())." }
        if money < p { return "Not enough money for \(Economy.goods[good].name)." }
        money -= p
        cargo[good] += 1
        save()
        return "Bought \(Economy.goods[good].name) for \(p)."
    }

    func sell(_ good: Int, at stage: Int) -> String {
        if cargo[good] == 0 { return "You have no \(Economy.goods[good].name) to sell." }
        let p = Economy.price(good, at: stage) * 9 / 10   // traders keep a margin
        money += p
        cargo[good] -= 1
        save()
        return "Sold \(Economy.goods[good].name) for \(p)."
    }

    func upgrade() -> String {
        guard transport + 1 < Economy.transports.count else { return "There is nothing better to travel in." }
        let next = Economy.transports[transport + 1]
        if money < next.cost { return "\(next.name) costs \(next.cost); you have \(money)." }
        money -= next.cost
        transport += 1
        save()
        return "You now travel by \(next.name.lowercased())."
    }

    func stall(at stage: Int) -> String {
        let s = Route.stages[stage]
        var text = "\(Economy.trader(at: stage))'s stall, \(s.name) · money \(money) · carrying \(carried)/\(vehicle.capacity) · \(vehicle.name)\n"
        for (k, g) in Economy.offer(at: stage).enumerated() {
            let good = Economy.goods[g]
            text += "  \(k + 1)  \(good.name) \(Economy.price(g, at: stage))\(good.home == s.country ? " (local)" : "") · you have \(cargo[g])\n"
        }
        text += "  1-6 buy · Shift+1-6 sell"
        if transport + 1 < Economy.transports.count {
            let next = Economy.transports[transport + 1]
            text += " · T buy \(next.name.lowercased()) (\(next.cost))"
        }
        return text
    }
}
