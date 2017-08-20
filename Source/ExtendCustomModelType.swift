//
//  ExtendCustomType.swift
//  HandyJSON
//
//  Created by zhouzhuo on 16/07/2017.
//  Copyright © 2017 aliyun. All rights reserved.
//

import Foundation

public protocol _ExtendCustomModelType: _Transformable {
    init()
    mutating func mapping(mapper: HelpingMapper)
}

extension _ExtendCustomModelType {

    public mutating func mapping(mapper: HelpingMapper) {}
}

fileprivate func convertKeyIfNeeded(dict: NSDictionary) -> NSDictionary {
    if HandyJSONConfiguration.deserializeOptions.contains(.caseInsensitive) {
        let newDict = NSMutableDictionary()
        dict.allKeys.forEach({ (key) in
            if let sKey = key as? String {
                newDict[sKey.lowercased()] = dict[key]
            } else {
                newDict[key] = dict[key]
            }
        })
        return newDict
    }
    return dict
}

fileprivate func getRawValueFrom(dict: NSDictionary, property: PropertyInfo, mapper: HelpingMapper) -> NSObject? {
    if let mappingHandler = mapper.getMappingHandler(key: property.address.hashValue) {
        if let mappingNames = mappingHandler.mappingNames, mappingNames.count > 0 {
            for mappingName in mappingNames {
                if let _value = dict[mappingName] {
                    return _value as? NSObject
                }
            }
            return nil
        }
    }
    if HandyJSONConfiguration.deserializeOptions.contains(.caseInsensitive) {
        return dict[property.key.lowercased()] as? NSObject
    }
    return dict[property.key] as? NSObject
}

fileprivate func convertValue(rawValue: NSObject, property: PropertyInfo, mapper: HelpingMapper) -> Any? {
    if let mappingHandler = mapper.getMappingHandler(key: property.address.hashValue), let transformer = mappingHandler.assignmentClosure {
        return transformer(rawValue)
    }
    if let transformableType = property.type as? _Transformable.Type {
        return transformableType.transform(from: rawValue)
    } else {
        return extensions(of: property.type).takeValue(from: rawValue)
    }
}

fileprivate func assignProperty(convertedValue: Any, instance: _ExtendCustomModelType, property: PropertyInfo) {
    if property.bridged {
        (instance as! NSObject).setValue(convertedValue, forKey: property.key)
    } else {
        extensions(of: property.type).write(convertedValue, to: property.address)
    }
}

fileprivate func readAllChildrenFrom(mirror: Mirror) -> [(String, Any)] {
    var children = [(label: String?, value: Any)]()
    let mirrorChildrenCollection = AnyRandomAccessCollection(mirror.children)!
    children += mirrorChildrenCollection

    var currentMirror = mirror
    while let superclassChildren = currentMirror.superclassMirror?.children {
        let randomCollection = AnyRandomAccessCollection(superclassChildren)!
        children += randomCollection
        currentMirror = currentMirror.superclassMirror!
    }
    var result = [(String, Any)]()
    children.forEach { (child) in
        if let _label = child.label {
            result.append((_label, child.value))
        }
    }
    return result
}

fileprivate func merge(children: [(String, Any)], propertyInfos: [PropertyInfo]) -> [String: (Any, PropertyInfo?)] {
    var infoDict = [String: PropertyInfo]()
    propertyInfos.forEach { (info) in
        infoDict[info.key] = info
    }

    var result = [String: (Any, PropertyInfo?)]()
    children.forEach { (child) in
        result[child.0] = (child.1, infoDict[child.0])
    }
    return result
}

extension _ExtendCustomModelType {

    static func _transform(from object: NSObject) -> Self? {
        if let dict = object as? NSDictionary {
            // nested object, transform recursively
            return self._transform(dict: dict, toType: self) as? Self
        }
        return nil
    }

    static func _transform(dict: NSDictionary, toType: _ExtendCustomModelType.Type) -> _ExtendCustomModelType? {
        var instance = toType.init()

        guard let properties = getProperties(forType: toType) else {
            InternalLogger.logDebug("Failed when try to get properties from type: \(type(of: toType))")
            return nil
        }

        // do user-specified mapping first
        let mapper = HelpingMapper()
        instance.mapping(mapper: mapper)

        // get head addr
        let rawPointer = instance.headPointer()
        InternalLogger.logVerbose("instance start at: ", rawPointer.hashValue)

        // process dictionary
        let _dict = convertKeyIfNeeded(dict: dict)

        let instanceIsNsObject = instance.isNSObjectType()
        let bridgedPropertyList = instance.getBridgedPropertyList()

        properties.forEach { (property) in
            let isBridgedProperty = instanceIsNsObject && bridgedPropertyList.contains(property.key)

            let propAddr = rawPointer.advanced(by: property.offset)
            InternalLogger.logVerbose(property.key, "address at: ", propAddr.hashValue)
            if mapper.propertyExcluded(key: propAddr.hashValue) {
                InternalLogger.logDebug("Exclude property: \(property.key)")
                return
            }

            let propertyDetail = PropertyInfo(key: property.key, type: property.type, address: propAddr, bridged: isBridgedProperty)
            InternalLogger.logVerbose("field: ", property.key, "  offset: ", property.offset, "  isBridgeProperty: ", isBridgedProperty)

            if let rawValue = getRawValueFrom(dict: _dict, property: propertyDetail, mapper: mapper) {
                if let convertedValue = convertValue(rawValue: rawValue, property: propertyDetail, mapper: mapper) {
                    assignProperty(convertedValue: convertedValue, instance: instance, property: propertyDetail)
                    return
                }
            }
            InternalLogger.logDebug("Property: \(property.key) hasn't been written in")
        }
        return instance
    }
}

extension _ExtendCustomModelType {

    func _plainValue() -> Any? {
        return Self._serializeAny(object: self)
    }

    static func _serializeAny(object: _Transformable) -> Any? {

        let mirror = Mirror(reflecting: object)

        guard let displayStyle = mirror.displayStyle else {
            return object.plainValue()
        }

        // after filtered by protocols above, now we expect the type is pure struct/class
        switch displayStyle {
        case .class, .struct:
            let mapper = HelpingMapper()
            // do user-specified mapping first
            if !(object is _ExtendCustomModelType) {
                InternalLogger.logDebug("This model of type: \(type(of: object)) is not mappable but is class/struct type")
                return object
            }

            let children = readAllChildrenFrom(mirror: mirror)

            guard let properties = getProperties(forType: type(of: object)) else {
                InternalLogger.logError("Can not get properties info for type: \(type(of: object))")
                return nil
            }

            var mutableObject = object as! _ExtendCustomModelType
            let instanceIsNsObject = mutableObject.isNSObjectType()
            let head = mutableObject.headPointer()
            let bridgedProperty = mutableObject.getBridgedPropertyList()
            let propertyInfos = properties.map({ (desc) -> PropertyInfo in
                return PropertyInfo(key: desc.key, type: desc.type, address: head.advanced(by: desc.offset),
                                        bridged: instanceIsNsObject && bridgedProperty.contains(desc.key))
            })

            mutableObject.mapping(mapper: mapper)

            let requiredInfo = merge(children: children, propertyInfos: propertyInfos)

            return _serializeModelObject(instance: mutableObject, properties: requiredInfo, mapper: mapper) as Any
        default:
            return object.plainValue()
        }
    }

    static func _serializeModelObject(instance: _ExtendCustomModelType, properties: [String: (Any, PropertyInfo?)], mapper: HelpingMapper) -> [String: Any] {

        var dict = [String: Any]()
        for (key, property) in properties {
            var realKey = key
            var realValue = property.0

            if let info = property.1 {
                if info.bridged, let _value = (instance as! NSObject).value(forKey: key) {
                    realValue = _value
                }

                if mapper.propertyExcluded(key: info.address.hashValue) {
                    continue
                }

                if let mappingHandler = mapper.getMappingHandler(key: info.address.hashValue) {
                    // if specific key is set, replace the label
                    if let mappingNames = mappingHandler.mappingNames, mappingNames.count > 0 {
                        // take the first if more than one
                        realKey = mappingNames[0]
                    }

                    if let transformer = mappingHandler.takeValueClosure {
                        if let _transformedValue = transformer(realValue) {
                            dict[realKey] = _transformedValue
                        }
                        continue
                    }
                }
            }

            if let typedValue = realValue as? _Transformable {
                if let result = self._serializeAny(object: typedValue) {
                    dict[realKey] = result
                    continue
                }
            }

            InternalLogger.logDebug("The value for key: \(key) is not transformable type")
        }
        return dict
    }
}

