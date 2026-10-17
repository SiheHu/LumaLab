import Foundation

package struct RecoveryRecord:Codable {
    package var sourceName:String
    package var dataFilename:String
    package var digest:String
    package var sourcePath:String?
    package var projectPath:String?
    package var edits:EditState
    package var savedState:EditState?
    package var snapshots:[SavedSnapshot]
    package var virtualCopies:[SavedSnapshot]
    package var history:[EditState]
    package var historyIndex:Int
    package var structureDirty:Bool
    package var newDocument:Bool
    package init(sourceName:String,dataFilename:String,digest:String,sourcePath:String?=nil,projectPath:String?=nil,edits:EditState,savedState:EditState?=nil,snapshots:[SavedSnapshot],virtualCopies:[SavedSnapshot],history:[EditState],historyIndex:Int,structureDirty:Bool,newDocument:Bool) {
        self.sourceName=sourceName
        self.dataFilename=dataFilename
        self.digest=digest
        self.sourcePath=sourcePath
        self.projectPath=projectPath
        self.edits=edits
        self.savedState=savedState
        self.snapshots=snapshots
        self.virtualCopies=virtualCopies
        self.history=history
        self.historyIndex=historyIndex
        self.structureDirty=structureDirty
        self.newDocument=newDocument
    }
}
