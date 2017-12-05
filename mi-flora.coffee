module.exports = (env) ->
  Promise = env.require 'bluebird'

  events = require 'events'

  class MiFloraPlugin extends env.plugins.Plugin
    init: (app, @framework, @config) =>
      @devices = {}

      deviceConfigDef = require('./device-config-schema')
      @framework.deviceManager.registerDeviceClass('MiFloraDevice', {
        configDef: deviceConfigDef.MiFloraDevice,
        createCallback: (config, lastState) =>
          device = new MiFloraDevice(config, @, lastState)
          @addToScan config.uuid, device
          return device
      })

      @framework.deviceManager.on 'discover', (eventData) =>
          @framework.deviceManager.discoverMessage 'pimatic-mi-flora', 'Scanning for Mi Flora plant sensors'

          @ble.on 'discover-mi-flora', (peripheral) =>
            env.logger.debug 'Device %s found, state: %s', peripheral.uuid, peripheral.state
            config = {
              class: 'MiFloraDevice',
              uuid: peripheral.uuid
            }
            @framework.deviceManager.discoveredDevice(
              'pimatic-mi-flora', 'Mi Flora plant sensor ' + peripheral.uuid, config
            )

      @framework.on 'after init', =>
        @ble = @framework.pluginManager.getPlugin 'ble'
        if @ble?
          @ble.registerName 'Flower mate', 'mi-flora'
          @ble.registerName 'Flower care', 'mi-flora'

          for uuid, device of @devices
            @ble.on 'discover-' + uuid, (peripheral) =>
              device = @devices[peripheral.uuid]
              env.logger.debug 'Device %s found, state: %s', device.name, peripheral.state
              #@removeFromScan peripheral.uuid
              device.connect peripheral
            @ble.addToScan uuid, device
        else
          env.logger.warn 'mi-flora could not find ble. It will not be able to discover devices'

    addToScan: (uuid, device) =>
      env.logger.debug 'Adding device %s', uuid
      if @ble?
        @ble.on 'discover-' + uuid, (peripheral) =>
          device = @devices[peripheral.uuid]
          env.logger.debug 'Device %s found, state: %s', device.name, peripheral.state
          #@removeFromScan peripheral.uuid
          device.connect peripheral
        @ble.addToScan uuid, device
      @devices[uuid] = device

    removeFromScan: (uuid) =>
      env.logger.debug 'Removing device %s', uuid
      if @ble?
        @ble.removeFromScan uuid
      if @devices[uuid]
        delete @devices[uuid]

  class MiFloraDevice extends env.devices.Sensor
    attributes:
      temperature:
        description: ''
        type: 'number'
        unit: '°C'
      light:
        description: ''
        type: 'number'
        unit: 'lx'
      moisture:
        description: ''
        type: 'number'
        unit: '%'
      fertility:
        description: ''
        type: 'number'
        unit: 'µS/cm'
      battery:
        description: 'State of battery'
        type: 'number'
        unit: '%'

    DATA_SERVICE_UUID = '0000120400001000800000805f9b34fb'
    DATA_CHARACTERISTIC_UUID = '00001a0100001000800000805f9b34fb'
    FIRMWARE_CHARACTERISTIC_UUID = '00001a0200001000800000805f9b34fb'
    REALTIME_CHARACTERISTIC_UUID = '00001a0000001000800000805f9b34fb'
    REALTIME_META_VALUE = Buffer.from([ 0xA0, 0x1F ])
    SERVICE_UUIDS = [ DATA_SERVICE_UUID ]
    CHARACTERISTIC_UUIDS = [ DATA_CHARACTERISTIC_UUID, FIRMWARE_CHARACTERISTIC_UUID, REALTIME_CHARACTERISTIC_UUID ]

    constructor: (@config, plugin, lastState) ->
      @id = @config.id
      @name = @config.name
      @interval = @config.interval
      @uuid = @config.uuid
      @peripheral = null
      @plugin = plugin

      @temperature = lastState?.temperature?.value or 0.0
      @light = lastState?.light?.value or 0
      @moisture = lastState?.moisture?.value or 0
      @fertility = lastState?.fertility?.value or 0
      @battery = lastState?.battery?.value or 0.0
      @_presence = false
      #@_presence = lastState?.presence?.value or false

      super()

    connect: (peripheral) ->
      @peripheral = peripheral

      @peripheral.on 'disconnect', (error) =>
        env.logger.debug 'Device %s disconnected', @name

      clearInterval @reconnectInterval
      if @_destroyed then return
      @reconnectInterval = setInterval( =>
        @_connect()
      , @interval)
      @_connect()

    _connect: ->
      if @_destroyed then return
      if @peripheral.state == 'disconnected'
        env.logger.debug 'Trying to connect to %s', @name
        @plugin.ble.stopScanning()
        @peripheral.connect (error) =>
          if !error
            env.logger.debug 'Device %s connected', @name
            #ToDo @_setPresence true
            @readData @peripheral
          else
            env.logger.debug 'Device %s connection failed: %s', @name, error
            #ToDo @_setPresence false
          @plugin.ble.startScanning()

    readData: (peripheral) ->
      env.logger.debug 'Reading data from %s', @name
      peripheral.discoverSomeServicesAndCharacteristics @SERVICE_UUIDS, @CHARACTERISTIC_UUIDS, (error, services, characteristics) =>
        characteristics.forEach (characteristic) =>
          switch characteristic.uuid
            when DATA_CHARACTERISTIC_UUID
              characteristic.read (error, data) =>
                @parseData peripheral, data
            when FIRMWARE_CHARACTERISTIC_UUID
              characteristic.read (error, data) =>
                @parseFirmwareData peripheral, data
            when REALTIME_CHARACTERISTIC_UUID
              env.logger.debug 'enabling realtime'
              characteristic.write REALTIME_META_VALUE, false
            #else
            #  characteristic.read (error, data) =>
            #    env.logger.debug 'found characteristic uuid %s but not matched the criteria', characteristic.uuid
            #    env.logger.debug '%s: %s (%s)', characteristic.uuid, data, error

    parseData: (peripheral, data) ->
      @temperature = data.readUInt16LE(0) / 10
      @light = data.readUInt32LE(3)
      @moisture = data.readUInt16BE(6)
      @fertility = data.readUInt16LE(8)
      env.logger.debug 'temperature: %s °C', @temperature
      env.logger.debug 'Light: %s lux', @light
      env.logger.debug 'moisture: %s%', @moisture
      env.logger.debug 'fertility: %s µS/cm', @fertility
      @emit 'temperature', @temperature
      @emit 'light', @light
      @emit 'moisture', @moisture
      @emit 'fertility', @fertility

    parseFirmwareData: (peripheral, data) ->
      @battery = parseInt(data.toString('hex', 0, 1), 16)
      @firmware = data.toString('ascii', 2, data.length)
      env.logger.debug 'firmware: %s', @firmware
      env.logger.debug 'battery: %s%', @battery
      @emit 'battery', @battery
    
    destroy: ->
      env.logger.debug 'Destroy %s', @name
      @_destroyed = true
      @emit('destroy', @)
      @removeAllListeners('destroy')
      @removeAllListeners(attrName) for attrName of @attributes

      if @peripheral && @peripheral.state == 'connected'
        @peripheral.disconnect()
      @plugin.removeFromScan @uuid
      super()

      clearInterval(@reconnectInterval)

    getTemperature: -> Promise.resolve @temperature
    getLight: -> Promise.resolve @light
    getMoisture: -> Promise.resolve @moisture
    getFertility: -> Promise.resolve @fertility
    getBattery: -> Promise.resolve @battery

  return new MiFloraPlugin
