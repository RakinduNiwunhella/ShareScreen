import Foundation

final class MDNSAdvertiser {
    private var service: NetService?

    func start(name: String, port: Int, txt: [String: String]) {
        stop()
        let svc = NetService(domain: "local.", type: "_sharedisplay._tcp.", name: name, port: Int32(port))
        let data = NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) })
        svc.setTXTRecord(data)
        svc.publish(options: [])
        service = svc
    }

    func stop() {
        service?.stop()
        service = nil
    }
}
