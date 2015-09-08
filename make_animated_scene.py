import bpy


class Obj(object):

  def __init__(self, fn, obj_name):

    self.obj_name = obj_name
    self.obj = self.__import(fn)

    return

  def __import(self, fn):

    bpy.ops.object.select_all(action='DESELECT')

    bpy.ops.import_scene.obj(
      filepath=fn,
      use_smooth_groups=False,
      use_edges=True,
    )

    obj = bpy.context.selected_objects[0]

    return obj

  def move_rescale(self, pos, scale):

    #obj_name = self.obj_name
    bpy.ops.object.origin_set(type='GEOMETRY_ORIGIN')

    #o = bpy.data.objects[obj_name]
    obj = self.obj

    sx,sy,sz = obj.scale

    sx *= scale
    sy *= scale
    sz *= scale

    obj.scale = ((sx,sy,sz))
    #bpy.data.objects[obj_name].dimensions.z *= scale

  def smooth(self, levels):

    bpy.context.scene.objects.active = self.obj
    #bpy.context.scene.objects.selected = self.obj

    bpy.ops.object.modifier_add(type='SUBSURF')
    self.obj.modifiers['Subsurf'].levels = levels
    self.obj.modifiers['Subsurf'].render_levels = levels

    bpy.ops.object.shade_smooth()

  def __set_vis(self, frame, vis=True):

    bpy.context.scene.objects.active = self.obj

    bpy.data.scenes['Scene'].frame_current = frame
    bpy.context.active_object.hide = not vis
    bpy.context.active_object.hide_render = not vis

    bpy.context.active_object.keyframe_insert(
      data_path="hide",
      index=-1,
      frame=frame
    )
    bpy.context.active_object.keyframe_insert(
      data_path="hide_render",
      index=-1,
      frame=frame
    )

  def animate_vis(self, ain, aout):

    self.__set_vis(0, False)
    self.__set_vis(ain, True)
    self.__set_vis(aout, False)

  def apply_mat(self):

    mat = bpy.data.materials["Material"]
    self.obj.data.materials.append(mat)


def main(argv):

  from time import time
  import glob, os

  name = argv[0]
  dirname = './res/'

  objs = []

  count = 0

  os.chdir(dirname)
  for fn in sorted(glob.glob('{:s}_*.obj'.format(name))):

    print('importing: ' + fn)

    t1 = time()

    O = Obj(fn,'a')
    O.smooth(1)
    O.move_rescale([-0.5]*3, 100)
    O.animate_vis(count, count+1)
    O.apply_mat()
    objs.append(O)

    count += 1

    print('\ntime:',time()-t1,'\n\n')

  bpy.data.scenes['Scene'].frame_current = 1
  bpy.data.scenes['Scene'].frame_end = count-1

  os.chdir('..')
  bpy.ops.wm.save_as_mainfile(filepath='./scene_{:s}.blend'.format(name))


if __name__ == '__main__':

  import sys
  argv = sys.argv
  argv = argv[argv.index("--") + 1:]
  main(argv)
